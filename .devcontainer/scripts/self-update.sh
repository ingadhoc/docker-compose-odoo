#!/usr/bin/env bash
# self-update.sh — corre en el HOST antes de `docker compose up`, disparado por
# initialize.sh (initializeCommand en devcontainer.json). Actúa sobre la versión
# que estás levantando (este clone), no sobre las hermanas de ~/odoo/.
#
# Pone al día las dos cosas que envejecen solas entre rebuild y rebuild:
#   1. el clone de docker-compose-odoo — fast-forward de main;
#   2. la imagen ${ODOO_IMAGE}:${ODOO_MINOR} — a lo sumo una vez por día.
#
# Lo que NO hace: tocar los archivos que init.sh patchea por versión
# (lib/managed-files.sh). Si el fast-forward los tocara, no mergea nada y te
# manda a `./init.sh`, que es quien sabe re-aplicar esos patches. Un ff a secas
# te dejaría el .env de upstream con el DOMAIN y el ODOO_VERSION de otra versión.
#
# Nunca voltea el arranque: todo fallo es un warning y el devcontainer sigue.
# Opt-out: SKIP_SELF_UPDATE=1. Ventana del pull de imagen:
# SELF_UPDATE_IMAGE_MAX_AGE (segundos, default 86400).

# Las llaves no son cosméticas. El fast-forward de acá abajo puede reescribir
# este mismo archivo mientras bash lo está ejecutando, y bash lee el script por
# offset: envuelto así lo parsea entero antes de correr la primera línea.
{
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAMP="${REPO_ROOT}/.devcontainer/.last-image-pull"
IMAGE_MAX_AGE="${SELF_UPDATE_IMAGE_MAX_AGE:-86400}"

# shellcheck source=lib/managed-files.sh
source "${SCRIPT_DIR}/lib/managed-files.sh"

log()  { echo "self-update: $*"; }
warn() { echo "self-update: WARN — $*" >&2; }

# GNU y BSD stat no comparten sintaxis.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# `timeout` es de coreutils: en macOS no viene.
with_timeout() {
    local secs="$1"; shift
    if command -v timeout &>/dev/null; then timeout "$secs" "$@"; else "$@"; fi
}

update_repo() {
    local branch upstream remote local_sha remote_sha base out f m
    local -a touched=()

    branch="$(git symbolic-ref --short -q HEAD)" || {
        log "detached HEAD — no toco el clone."; return; }
    if [[ "$branch" != "main" ]]; then
        log "estás en '$branch' y no en main — no toco el clone."; return
    fi

    upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
    if [[ -z "$upstream" ]]; then
        if git remote get-url origin &>/dev/null; then
            upstream="origin/main"
        else
            warn "main no tiene upstream ni hay remote origin — no actualizo el clone."
            return
        fi
    fi
    remote="${upstream%%/*}"

    # Sin estas dos no hay a quién pedirle una passphrase o un usuario: el
    # initializeCommand corre sin tty y un prompt cuelga el arranque entero.
    export GIT_TERMINAL_PROMPT=0
    export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

    if ! with_timeout 30 git fetch --quiet "$remote" "${upstream#*/}"; then
        warn "no pude traer $upstream (¿sin red, o la llave pide passphrase?) — sigo sin actualizar el clone."
        return
    fi

    local_sha="$(git rev-parse HEAD)"
    remote_sha="$(git rev-parse "$upstream")"
    if [[ "$local_sha" == "$remote_sha" ]]; then
        log "el clone ya está al día con $upstream."
        return
    fi

    base="$(git merge-base HEAD "$upstream")"
    if [[ "$base" != "$local_sha" ]]; then
        warn "main diverge de $upstream (tenés commits propios acá) — no toco el clone."
        return
    fi

    while IFS= read -r f; do
        for m in "${MANAGED_FILES[@]}"; do
            [[ "$f" == "$m" ]] && touched+=("$f")
        done
    done < <(git diff --name-only "$local_sha" "$remote_sha")

    if (( ${#touched[@]} > 0 )); then
        warn "hay $(git rev-list --count "${local_sha}..${remote_sha}") commit(s) nuevos y tocan archivos que init.sh patchea por versión:"
        printf 'self-update:   %s\n' "${touched[@]}" >&2
        warn "no actualizo el clone para no pisar esos patches. Ponelo al día a mano:"
        echo "self-update:   cd ${REPO_ROOT} && ./init.sh -u && git stash && git pull --ff-only && ./init.sh" >&2
        return
    fi

    if out="$(git merge --ff-only "$upstream" 2>&1)"; then
        log "clone actualizado: $(git rev-parse --short "$local_sha") → $(git rev-parse --short HEAD) ($(git rev-list --count "${local_sha}..HEAD") commit(s))."
    else
        warn "el fast-forward falló, el clone queda como estaba: ${out}"
    fi
}

update_image() {
    local age image before after
    local -a pull=(docker pull)

    if [[ ! -f "${REPO_ROOT}/.env" ]]; then
        warn "no hay .env — no sé qué imagen pullear. Corré ./init.sh."
        return
    fi

    if [[ -f "$STAMP" ]]; then
        age=$(( $(date +%s) - $(mtime "$STAMP") ))
        if (( age < IMAGE_MAX_AGE )); then
            log "imagen chequeada hace $(( age / 3600 ))h — no la vuelvo a pullear (ventana: $(( IMAGE_MAX_AGE / 3600 ))h)."
            return
        fi
    fi

    # En subshell: el .env es del dev y puede definir cualquier cosa.
    image="$(set +u; source "${REPO_ROOT}/.env" >/dev/null 2>&1; echo "${ODOO_IMAGE:-}:${ODOO_MINOR:-}")"
    if [[ "$image" == ":" ]]; then
        warn "el .env no define ODOO_IMAGE/ODOO_MINOR — no pulleo. Corré ./init.sh."
        return
    fi

    before="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)"
    log "pulleando ${image} ..."
    [[ "$OSTYPE" == darwin* && "$(uname -m)" == "arm64" ]] && pull+=(--platform linux/amd64)
    if ! "${pull[@]}" "$image"; then
        warn "falló el pull de ${image} — arranco con la imagen que ya tenías."
        return
    fi
    touch "$STAMP"

    after="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)"
    if [[ -n "$before" && "$before" != "$after" ]]; then
        log "⚠ imagen nueva para ${image}. Si el container no se recrea solo, corré 'Dev Containers: Rebuild Container'."
    fi
}

if [[ "${SKIP_SELF_UPDATE:-0}" == "1" ]]; then
    log "SKIP_SELF_UPDATE=1 — no actualizo nada."
    exit 0
fi

cd "$REPO_ROOT" || { warn "no pude entrar a ${REPO_ROOT}."; exit 0; }
update_repo
update_image
exit 0
}
