#!/usr/bin/env bash
# gcloud-sync.sh — copia la config de gcloud del host al dir canónico del
# container. Corre solo (postCreate + cada start del container) y a mano
# cuando hace falta: está en el PATH como `gcloud-sync.sh`.
#
# ── Por qué una copia y no el mount directo ────────────────────────────────
# El dir de gcloud del host se montea READ-ONLY (en `$HOME/.gcloud-host`), y
# read-only rompe gcloud: renovar la sesión es una operación de ESCRITURA.
# Verificado adentro del container con el dir montado `:ro`:
#
#   ERROR: (gcloud.auth.print-access-token) Unable to create private file
#   [~/.config/gcloud/credentials.db]: [Errno 30] Read-only file system
#
# Y montar `:rw` solo el par de archivos del token tampoco alcanza: sqlite
# escribe su journal AL LADO del .db (o sea, necesita el dir writable), y
# gcloud además escribe `logs/` en cada invocación.
#
# La copia deja las dos cosas: adentro se puede renovar el token (y hasta
# hacer `gcloud auth login` o `config set`, que quedan locales al container),
# y el estado del host es FÍSICAMENTE inmodificable desde acá — un
# `gcloud auth revoke` adentro no le toca la sesión al dev.
#
# ── Contrapartida: la copia es una FOTO, y el reauth vence ─────────────────
# La cuenta de Workspace tiene política de reauth: además del refresh token,
# gcloud guarda en `credentials.db` una prueba de reautenticación (RAPT) que
# caduca cada pocas horas y se renueva sola cuando el dev usa gcloud en el
# host (ahí puede promptear). Una copia con el RAPT vencido no puede renovar
# nada y falla así — con `auth list` andando igual, que es lo confuso:
#
#   ERROR: (gcloud.auth.print-access-token) There was a problem refreshing
#   your current auth tokens: Reauthentication failed. cannot prompt during
#   non-interactive execution.
#
# La cura es re-correr este script (trae el RAPT fresco del host). Ya corre en
# cada start del container; si el dev se reautentica en el host con la sesión
# abierta, lo corre a mano: `gcloud-sync.sh`.
#
# Verificado 2026-09-05: con la copia al día el container renueva de verdad
# (borrando `access_tokens.db` de la copia mintea un token NUEVO, distinto al
# del host) y el `access_tokens.db` del host queda sin tocar.
#
# `~/.kube` NO necesita este tratamiento: con el dir read-only el
# gke-gcloud-auth-plugin mintea igual (verificado) — solo pierde su cache, así
# que paga una llamada a gcloud por invocación de kubectl. Lo único que no se
# puede hacer adentro es `kubectl config use-context`, que justamente es el
# tipo de cambio que no queremos que se filtre al host.

set -euo pipefail

SRC="${GCLOUD_HOST_DIR:-$HOME/.gcloud-host}"
DEST="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"

# Caches regenerables y grandes: `cli/` son 121 MB de árbol de comandos y
# `logs/` 63 MB de histórico de invocaciones del host. Nada de eso es
# credencial ni configuración; gcloud los rearma solo adentro si los necesita.
EXCLUDE=(logs cli)

if [ ! -d "$SRC" ]; then
    echo "gcloud-sync: no hay config de gcloud del host en $SRC — nada que hacer."
    echo "             (la montea discover-mounts.sh con R2_ENABLE_DEVOPS=1 en el host)"
    exit 0
fi

mkdir -p "$DEST"
if ! touch "$DEST/.rw-probe" 2>/dev/null; then
    echo "gcloud-sync: FALLO — $DEST no es writable." >&2
    echo "             Si sigue montado read-only desde el host, rebuildeá el container:" >&2
    echo "             el dir del host pasó a montearse en $SRC y este queda writable" >&2
    echo "             adentro (ver discover-mounts.sh)." >&2
    exit 1
fi
rm -f "$DEST/.rw-probe"

# `-name X -prune -o -print0` incluye dotfiles (.metricsUUID, .last_*_prompt.yaml)
# y no baja a los dirs excluidos. El `rm -rf` previo por entrada evita el clásico
# `cp -a dir dest/` cuando `dest/dir` ya existe (copiaría dest/dir/dir).
prune_args=()
for name in "${EXCLUDE[@]}"; do
    prune_args+=(-name "$name" -prune -o)
done

count=0
while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    rm -rf "$DEST/$name"
    cp -a "$entry" "$DEST/$name"
    count=$((count + 1))
done < <(find "$SRC" -mindepth 1 -maxdepth 1 "${prune_args[@]}" -print0)

echo "gcloud-sync: $count entradas copiadas de $SRC → $DEST (excluye: ${EXCLUDE[*]})."
