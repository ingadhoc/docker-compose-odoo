#!/bin/bash
# Vigila la presión de memoria del propio container y reinicia el language
# server más pesado antes de que el cgroup empiece a matar procesos a ciegas.
#
# El problema: Pylance y el Odoo LS indexan todos los addons_paths y su working
# set crece de forma monotónica — lo analizado entra al índice y no sale. En un
# devcontainer con decenas de repos son ~20k archivos .py, y un proceso de un
# día llega a 5-8 GB. Con varios devcontainers abiertos el host se queda sin
# RAM, empieza a paginar y termina congelándose.
#
# Solo reinicia language servers: procesos que VS Code relanza solo y cuyo
# único estado es un índice regenerable. Nunca toca Odoo, postgres, shells
# ni agentes.
#
# Se mide contra el mem_limit del container cuando existe; si no hay límite,
# contra una fracción de la RAM del host, para que escale entre máquinas.
# Ver doc/memoria.md.

set -uo pipefail

INTERVAL="${LS_WATCHDOG_INTERVAL:-60}"             # segundos entre chequeos
THRESHOLD_PCT="${LS_WATCHDOG_THRESHOLD_PCT:-85}"   # % del techo que dispara
FALLBACK_PCT="${LS_WATCHDOG_FALLBACK_PCT:-35}"     # sin mem_limit: % de la RAM del host
COOLDOWN="${LS_WATCHDOG_COOLDOWN:-600}"            # no matar de nuevo antes de esto
MIN_VICTIM_MB="${LS_WATCHDOG_MIN_VICTIM_MB:-1024}" # no matar algo chico al pedo
LOG="${LS_WATCHDOG_LOG:-/tmp/ls-watchdog.log}"
LOCKFILE="${LS_WATCHDOG_LOCK:-/tmp/ls-watchdog.lock}"
PIDFILE="${LS_WATCHDOG_PIDFILE:-/tmp/ls-watchdog.pid}"

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# --- idempotencia: un solo watchdog por container -------------------------
# flock y no un pidfile: el /tmp del container sobrevive un stop/start, pero
# los PIDs vuelven a empezar de números bajos. Un pidfile viejo puede matchear
# un proceso nuevo cualquiera y dejar el watchdog apagado en silencio. El lock
# lo suelta el kernel al cerrarse el fd, así que no puede quedar rancio.
# Fallback a pidfile verificado por cmdline si no hubiera flock.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCKFILE" 2>/dev/null || { log "no puedo abrir $LOCKFILE — salgo"; exit 0; }
    if ! flock -n 9; then
        log "ya hay un watchdog corriendo (lock $LOCKFILE tomado), salgo"
        exit 0
    fi
else
    if [ -f "$PIDFILE" ]; then
        _old=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$_old" ] && [ -r "/proc/$_old/cmdline" ] \
           && tr '\0' ' ' < "/proc/$_old/cmdline" 2>/dev/null | grep -q 'ls-watchdog\.sh'; then
            log "ya hay un watchdog corriendo (pid $_old), salgo"
            exit 0
        fi
        log "pidfile rancio (pid ${_old:-?} no es este script) — lo piso"
    fi
    trap 'rm -f "$PIDFILE"' EXIT
fi
echo $$ > "$PIDFILE"

# --- lectura del cgroup, v2 y v1 ------------------------------------------
# cgroup v2: /sys/fs/cgroup/{memory.current,memory.max}
# cgroup v1: /sys/fs/cgroup/memory/{memory.usage_in_bytes,memory.limit_in_bytes}
# En v1 "sin límite" es un número gigante (PAGE_COUNTER_MAX), no la string "max".
CG_V2_CUR=/sys/fs/cgroup/memory.current
CG_V2_MAX=/sys/fs/cgroup/memory.max
CG_V1_CUR=/sys/fs/cgroup/memory/memory.usage_in_bytes
CG_V1_MAX=/sys/fs/cgroup/memory/memory.limit_in_bytes
NO_LIMIT_FLOOR=$(( 1 << 62 ))   # por encima de esto, tratarlo como "sin límite"

current_bytes() {
    local v
    v=$(cat "$CG_V2_CUR" 2>/dev/null) && [ -n "$v" ] && { echo "$v"; return 0; }
    v=$(cat "$CG_V1_CUR" 2>/dev/null) && [ -n "$v" ] && { echo "$v"; return 0; }
    return 1
}

# Con mem_limit: el límite real del cgroup. Sin él, una fracción de MemTotal,
# así el umbral escala con la máquina en vez de ser un número fijo.
limit_bytes() {
    local m total_kb
    m=$(cat "$CG_V2_MAX" 2>/dev/null)
    if [ -n "$m" ] && [ "$m" != "max" ]; then
        echo "$m"; return
    fi
    m=$(cat "$CG_V1_MAX" 2>/dev/null)
    if [ -n "$m" ] && [ "$m" -lt "$NO_LIMIT_FLOOR" ] 2>/dev/null; then
        echo "$m"; return
    fi
    total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$total_kb" ]; then
        echo $(( total_kb * 1024 * FALLBACK_PCT / 100 ))
    else
        echo 0
    fi
}

# --- candidatos: solo language servers ------------------------------------
# Imprime "rss_kb pid etiqueta", ordenado descendente.
victims() {
    local pid cmd rss label
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        [ -r "/proc/$pid/cmdline" ] || continue
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        case "$cmd" in
            *vscode-pylance*server.bundle.js*) label="pylance" ;;
            *odoo_ls_server*)                  label="odoo-ls" ;;
            *)                                 continue ;;
        esac
        rss=$(awk '/^VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null)
        [ -n "$rss" ] && echo "$rss $pid $label"
    done | sort -rn
}

LIMIT=$(limit_bytes)
if [ "$LIMIT" -le 0 ]; then
    log "no puedo determinar un techo de memoria (ni cgroup ni /proc/meminfo) — salgo"
    exit 0
fi
if ! current_bytes >/dev/null; then
    log "no puedo leer el uso de memoria del cgroup (ni $CG_V2_CUR ni $CG_V1_CUR) — salgo"
    exit 0
fi
log "watchdog arriba (pid $$) — techo=$((LIMIT/1048576))MB umbral=${THRESHOLD_PCT}% intervalo=${INTERVAL}s"

last_kill=0
while :; do
    sleep "$INTERVAL"

    LIMIT=$(limit_bytes)   # relee: el mem_limit puede cambiar entre rebuilds
    [ "$LIMIT" -gt 0 ] || continue
    cur=$(current_bytes) || { log "dejé de poder leer el uso del cgroup — salgo"; exit 0; }
    pct=$(( cur * 100 / LIMIT ))

    [ "$pct" -lt "$THRESHOLD_PCT" ] && continue

    now=$(date +%s)
    if [ $(( now - last_kill )) -lt "$COOLDOWN" ]; then
        log "container al ${pct}% pero en cooldown ($(( COOLDOWN - (now - last_kill) ))s restantes)"
        continue
    fi

    read -r rss pid label <<< "$(victims | head -1)"
    if [ -z "${pid:-}" ]; then
        log "container al ${pct}% pero no hay language server candidato"
        continue
    fi
    if [ "$(( rss / 1024 ))" -lt "$MIN_VICTIM_MB" ]; then
        log "container al ${pct}% pero el candidato mayor ($label, $((rss/1024))MB) es chico — no vale la pena"
        continue
    fi

    log "container al ${pct}% ($((cur/1048576))MB de $((LIMIT/1048576))MB) — SIGTERM a $label pid=$pid ($((rss/1024))MB)"
    if kill -TERM "$pid" 2>/dev/null; then
        last_kill=$now
        log "  -> señalizado; VS Code lo relanza"
    else
        log "  -> no se pudo señalizar pid=$pid"
    fi
done
