#!/bin/bash
# Comparte sesiones de Claude Code host↔container creando symlinks de los
# nombres encoded del container hacia los del host. Idempotente, corre rápido.
#
# Claude encoda el path absoluto del workspace en el nombre del dir bajo
# ~/.claude/projects/, reemplazando cada carácter NO alfanumérico por `-`
# (regla oficial — docs "sessions"). Como host y container montan el mismo
# repo en paths distintos, cada uno encoda distinto y la historia se parte.
# No hay feature nativa de Claude para aliasear proyectos ni redirigir el store
# de sesiones (verificado contra docs + changelog); el symlink es la vía.
#
# Dos clases de "mismo repo, dos paths":
#
#   1. Árbol `custom` (bind base ./data/custom → /home/odoo/custom):
#        Host:      -home-<user>-odoo-<v>-data-custom(-<rest>)?
#        Container: -home-odoo-custom(-<rest>)?
#      Transformación puramente por string sobre el nombre encoded — no
#      necesita saber el $HOME ni la versión del host (los lee del nombre).
#
#   2. Repos del ecosistema (devops, adhoc-way, tuqui, oba, …) montados por
#      discover-mounts.sh desde ~/repositorios/<id> del host hacia
#      /home/odoo/custom/<id> (bind anidado). Acá el path del host NO es
#      derivable del container, así que discover-mounts —que corre en el host y
#      conoce ambos lados resueltos— vuelca el mapeo a `.session-mounts.tsv`,
#      que viaja al container por el bind /scripts y leemos abajo.
#
# En ambos casos creamos symlink <container-encoded> → <host-encoded>: `/resume`
# adentro del container ve las sesiones del host, y las nuevas caen en el dir
# real del host vía el symlink (bidireccional). El dir del host es el canónico.
#
# Corre en postCreateCommand (vía poststart.sh) y postStartCommand (vía
# devcontainer.json), así proyectos nuevos abiertos en el host entre rebuilds o
# restarts quedan al día sin overhead. Ver ADR 0023 en adhoc-way para el
# contexto del bind mount host↔container.
#
# Límite conocido: solo bridgea el store de transcripts (~/.claude/projects/).
# El map `projects` de ~/.claude.json (trust, allowedTools, history) sigue
# keyed por path absoluto → host y container tienen entradas separadas.

set -euo pipefail

PROJECTS_DIR="$HOME/.claude/projects"
[ -d "$PROJECTS_DIR" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_MOUNTS="$SCRIPT_DIR/.session-mounts.tsv"

linked=0
merged=0
warned=0

# encode <path> → nombre de dir que usa Claude bajo ~/.claude/projects/
encode() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

# ensure_link <host_name> <container_name>
# $host_name es un dir real bajo PROJECTS_DIR. Deja $container_name como symlink
# → $host_name, mergeando primero un dir real preexistente (sesiones creadas en
# el container antes de tener el symlink). Idempotente.
ensure_link() {
    local host_name="$1" container_name="$2"
    [ "$host_name" = "$container_name" ] && return 0

    local container_path="$PROJECTS_DIR/$container_name"

    # Ya es symlink → idempotente.
    [ -L "$container_path" ] && return 0

    # Existe pero no es symlink ni dir (archivo regular u otro tipo): no lo
    # tocamos. Sin esto, `ln -s` fallaría y —por `set -e`— abortaría todo el
    # bridging por una sola entrada rara. Coherente con el WARN del merge.
    if [ -e "$container_path" ] && [ ! -d "$container_path" ]; then
        echo "share-claude-sessions: WARN — $container_path existe y no es symlink ni dir; se deja intacto." >&2
        warned=$((warned + 1))
        return 0
    fi

    # Dir real: mergear al dir del host y eliminarlo antes de symlinkear. Nunca
    # priorizamos sesiones del container sobre las del host compartido. `mv -n`
    # (no-clobber) evita pisar; los SESSION-ID.jsonl son únicos, no debería
    # haber colisiones. Si alguna queda, rmdir falla y avisamos.
    if [ -d "$container_path" ]; then
        mv -n "$container_path"/*     "$PROJECTS_DIR/$host_name"/ 2>/dev/null || true
        mv -n "$container_path"/.[!.]* "$PROJECTS_DIR/$host_name"/ 2>/dev/null || true
        if rmdir "$container_path" 2>/dev/null; then
            merged=$((merged + 1))
        else
            echo "share-claude-sessions: WARN — $container_path tiene archivos en conflicto con $PROJECTS_DIR/$host_name, no se mergeó. Revisar manual." >&2
            warned=$((warned + 1))
            return 0
        fi
    fi

    # `--` separa flags porque $host_name empieza con `-`.
    ln -s -- "$host_name" "$container_path"
    linked=$((linked + 1))
}

# ── Pass 1: repos del ecosistema (mapeo resuelto por discover-mounts) ────────
# Va primero: deja fijados los symlinks de container→host de estos repos, así
# el pass del árbol `custom` no intenta remapear el mismo nombre al mountpoint
# vacío `data/custom/<id>` (bind anidado shadoweado).
if [ -f "$SESSION_MOUNTS" ]; then
    while IFS=$'\t' read -r host_path container_target; do
        [ -n "${host_path:-}" ] && [ -n "${container_target:-}" ] || continue
        enc_host="$(encode "$host_path")"
        enc_container="$(encode "$container_target")"
        [ "$enc_host" = "$enc_container" ] && continue

        for host_proj in "$PROJECTS_DIR"/*; do
            [ -d "$host_proj" ] || continue
            [ -L "$host_proj" ] && continue
            host_name="$(basename "$host_proj")"
            case "$host_name" in
                "$enc_host")   ensure_link "$host_name" "$enc_container" ;;
                "$enc_host"-*) ensure_link "$host_name" "${enc_container}${host_name#"$enc_host"}" ;;
            esac
        done
    done < "$SESSION_MOUNTS"
fi

# ── Pass 2: árbol `custom` (transformación por string, sin mapeo externo) ────
for host_proj in "$PROJECTS_DIR"/*; do
    [ -d "$host_proj" ] || continue
    [ -L "$host_proj" ] && continue
    host_name="$(basename "$host_proj")"

    # Match: -home-<user>-odoo-<version>-data-custom(-<rest>)?
    case "$host_name" in
        -home-*-odoo-*-data-custom|-home-*-odoo-*-data-custom-*)
            # `<rest>` incluye su `-` líder, o queda vacío si es top-level.
            rest="${host_name#*-data-custom}"
            ensure_link "$host_name" "-home-odoo-custom${rest}"
            ;;
    esac
done

if [ "$linked" -gt 0 ] || [ "$merged" -gt 0 ] || [ "$warned" -gt 0 ]; then
    echo "share-claude-sessions: $merged dir(s) mergeado(s) + $linked symlink(s) creado(s) + $warned warning(s) en $PROJECTS_DIR."
fi
