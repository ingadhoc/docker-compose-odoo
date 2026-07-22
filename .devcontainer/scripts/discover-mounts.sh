#!/usr/bin/env bash
# discover-mounts.sh — corre en el HOST antes de `docker compose up`
# (gatillado por `initializeCommand` en devcontainer.json). Detecta qué
# proyectos del ecosistema adhoc-way están presentes en el host y genera
# `docker-compose.auto-mounts.yml` con los mounts correspondientes.
#
# Pieza simétrica a `for_each_mounted_project` en poststart.sh: aquél
# descubre adentro del container; éste descubre afuera, antes de que el
# container exista.
#
# Idempotente — se regenera en cada rebuild. NO EDITAR el archivo de salida
# a mano; para mounts custom (path no-default, repo fuera del catálogo) usá
# `docker-compose.override.yml` (opt-in manual, gitignored).
#
# Catálogo embebido más abajo. Es config opinionada de ESTE devcontainer
# (qué repos del ecosistema conviene montar al lado) — vive con el runtime,
# no es topología de ningún proyecto. Cada entry declara:
#   id              identificador corto (también nombre del dir en custom/).
#   host_path       path absoluto en host. Soporta ${HOME} y ${REPO_ROOT}
#                   (este último = path del propio repo docker-compose-odoo,
#                   permite self-mount sin path hardcodeado).
#   container_target target adentro del container (convención: custom/<id>).
#   requires        id de otro proyecto que debe estar presente, o vacío.
#                   Útil para mounts que dependen de otro (p.ej. self-mount
#                   docker-compose-odoo requiere devops mounteado, porque el
#                   target está adentro de custom/devops/).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT="${REPO_ROOT}/docker-compose.auto-mounts.yml"

# GCP legacy credentials: resolver cuenta activa antes de armar el catálogo.
_gcp_src=""
if command -v gcloud &>/dev/null; then
    _gcp_account="$(gcloud config get-value account 2>/dev/null || true)"
    if [[ -n "$_gcp_account" ]]; then
        _gcp_src="${HOME}/.config/gcloud/legacy_credentials/${_gcp_account}"
    fi
fi

PROJECTS=(
    "devops|${HOME}/repositorios/devops|/home/odoo/custom/devops|"
    "devops-it|${HOME}/repositorios/devops-it|/home/odoo/custom/devops-it|"
    "adhoc-way|${HOME}/repositorios/adhoc-way|/home/odoo/custom/adhoc-way|"
    "tuqui|${HOME}/tuqui|/home/odoo/custom/tuqui|"
    # oba y oba-project-memory quedan top-level sin prefijo (aunque son repos de
    # la org ingadhoc/): todo dev OBA los necesita, no son opt-in (regla aflojada
    # — ADR 0027). El PROYECTO es "oba" (mount custom/oba, clone ~/repositorios/oba);
    # el REPO es oba-project — el sufijo -project es del repo, no del proyecto
    # (ADR 0028 + 0039). oba = hub de specs/decisiones del producto OBA;
    # oba-project-memory = wiki/memoria (su nombre de repo NO se acorta).
    "oba|${HOME}/repositorios/oba|/home/odoo/custom/oba||git@github.com:ingadhoc/oba-project.git"
    "oba-project-memory|${HOME}/repositorios/oba-project-memory|/home/odoo/custom/oba-project-memory|"
    # Self-mount del propio docker-compose-odoo deshabilitado (mayo 2026):
    # cuando devops ya está mounteado, el bind anidado en
    # custom/devops/docker-compose-odoo aparece como dir dummy en lugar del
    # contenido real del repo host. Revisar más adelante — probablemente
    # con flag opt-in en lugar de auto, o cambiando el target fuera de
    # custom/devops/ para evitar el bind anidado.
    # "docker-compose-odoo|${REPO_ROOT}|/home/odoo/custom/devops/docker-compose-odoo|devops"
    "odumbo|${HOME}/repositorios/odumbo|/home/odoo/custom/odumbo|"
    "consultoria-tecnica|${HOME}/repositorios/consultoria-tecnica|/home/odoo/custom/consultoria-tecnica|"
)
[[ -n "$_gcp_src" ]] && PROJECTS+=("gcp-credentials|${_gcp_src}|/home/odoo/gcloud_legacy_credentials:ro|")

declare -A PRESENT=()
declare -A SOURCES=()
declare -A TARGETS=()

for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r id host target req git_url <<<"$entry"
    if [[ -d "$host" ]]; then
        PRESENT[$id]=1
        SOURCES[$id]="$host"
        TARGETS[$id]="$target"
    elif [[ -n "${git_url:-}" ]]; then
        echo "discover-mounts: $id no encontrado — clonando desde $git_url..." >&2
        if git clone "$git_url" "$host" >&2; then
            echo "discover-mounts: $id clonado OK → $host" >&2
            PRESENT[$id]=1
            SOURCES[$id]="$host"
            TARGETS[$id]="$target"
        else
            echo "discover-mounts: WARN — falló el clone de $id (mount omitido)" >&2
        fi
    fi
done

# Chequeo de `requires`: pase ÚNICO, no transitivo. Mira presencia-en-host del
# parent (PRESENT[$req] del primer loop), no si el parent sobrevivió a su propio
# requires. Alcanza para cadenas de 1 nivel (el caso de hoy: todos `requires: ""`).
# Si algún día se arma una cadena `A→B→C`, esto necesita iterar hasta punto fijo.
for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r id host target req git_url <<<"$entry"
    if [[ -n "$req" && -n "${PRESENT[$id]:-}" && -z "${PRESENT[$req]:-}" ]]; then
        unset "PRESENT[$id]"
        echo "discover-mounts: $id omitido (requiere $req mounteado)" >&2
    fi
done

detected=()
for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r id host target req git_url <<<"$entry"
    [[ -n "${PRESENT[$id]:-}" ]] && detected+=("$id")
done

# Mounts devops — solo si R2_ENABLE_DEVOPS=1 en el host.
# Agrega ~/.kube, ~/.config/gcloud y el socket de Docker al servicio odoo.
devops_mounts=()
if [[ "${R2_ENABLE_DEVOPS:-0}" == "1" ]]; then
    [[ -d "${HOME}/.kube" ]]           && devops_mounts+=("${HOME}/.kube:/home/odoo/.kube:ro")
    [[ -d "${HOME}/.config/gcloud" ]]  && devops_mounts+=("${HOME}/.config/gcloud:/home/odoo/.config/gcloud:ro")
    [[ -d "${HOME}/.docker" ]]         && devops_mounts+=("${HOME}/.docker:/home/odoo/.docker:ro")
    [[ -S /var/run/docker.sock ]]      && devops_mounts+=("/var/run/docker.sock:/var/run/docker.sock")
    echo "discover-mounts: R2_ENABLE_DEVOPS=1 — ${#devops_mounts[@]} mount(s) devops." >&2
fi

{
    echo "# docker-compose.auto-mounts.yml — AUTO-GENERATED por"
    echo "# .devcontainer/scripts/discover-mounts.sh (initializeCommand)."
    echo "# NO EDITAR A MANO: cambios se pierden en el próximo rebuild."
    echo "# Para mounts custom (path no-default) usá docker-compose.override.yml."
    echo "#"
    if (( ${#detected[@]} == 0 && ${#devops_mounts[@]} == 0 )); then
        echo "# Proyectos detectados: ninguno."
        echo ""
        echo "services:"
        echo "  odoo: {}"
    else
        if (( ${#detected[@]} > 0 )); then
            echo "# Proyectos detectados:"
            for id in "${detected[@]}"; do
                echo "#   $id  (${SOURCES[$id]} → ${TARGETS[$id]})"
            done
        fi
        echo ""
        echo "services:"
        echo "  odoo:"
        echo "    volumes:"
        for id in "${detected[@]}"; do
            echo "      - ${SOURCES[$id]}:${TARGETS[$id]}"
        done
        for mount in "${devops_mounts[@]}"; do
            echo "      - $mount"
        done
    fi
} > "$OUT"

if (( ${#detected[@]} == 0 )); then
    echo "discover-mounts: 0 proyectos del ecosistema detectados en host"
else
    echo "discover-mounts: ${#detected[@]} proyecto(s) detectado(s) → ${detected[*]}"
fi

# ── Mapeo de sesiones Claude para share-claude-sessions.sh ──────────────────
# Ese script corre DENTRO del container y necesita el path del HOST (resuelto,
# con $HOME ya expandido) de cada repo del ecosistema para bridgear la historia
# de sesiones de Claude host↔container (los repos se montan en /home/odoo/custom
# pero en el host viven en ~/repositorios/<id>, path no derivable adentro).
# Acá —en el host— tenemos ambos lados resueltos; los volcamos a un TSV que
# viaja al container por el bind /scripts. Solo repos bajo custom/ (los que un
# dev abre en Claude); credenciales/infra quedan afuera. Ver ADR 0023.
SESSION_MOUNTS="${SCRIPT_DIR}/.session-mounts.tsv"
{
    for id in "${detected[@]}"; do
        target="${TARGETS[$id]%%:*}"                     # sin modo (:ro)
        case "$target" in
            /home/odoo/custom/*) printf '%s\t%s\n' "${SOURCES[$id]}" "$target" ;;
        esac
    done
} > "$SESSION_MOUNTS"

# ── Aviso de mountpoints viejos en data/custom/ ─────────────────────────────
# El bind `./data/custom` (docker-compose.yml) PERSISTE en el host. Cuando se
# saca o renombra una entrada del catálogo (p.ej. oba-project → oba), su
# mountpoint queda como dir VACÍO en data/custom/ (root-owned, lo crea Docker).
# Lo avisamos acá —initializeCommand en el HOST— porque SIEMPRE se ve en el log
# del rebuild (el postStart, donde corre build_workspace, lo colapsa VS Code) y
# porque acá el dir del host es accesible directo. Discriminador: en el host
# TODOS los mountpoints están vacíos (el bind real se monta en runtime), así que
# "vacío" no alcanza — un dir es stale si está vacío Y su nombre NO está en el
# catálogo. El borrado necesita sudo → lo hace el dev; este script no toca nada.
CUSTOM_DIR="${REPO_ROOT}/data/custom"
if [[ -d "$CUSTOM_DIR" ]]; then
    declare -A _keep=()
    for entry in "${PROJECTS[@]}"; do
        IFS='|' read -r id host target req git_url <<<"$entry"
        case "$target" in /home/odoo/custom/*) _keep["$(basename "$target")"]=1 ;; esac
    done
    for s in repositories src adhoc; do _keep["$s"]=1; done   # dirs estructurales del workspace
    _stale=()
    for d in "$CUSTOM_DIR"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        [[ -n "${_keep[$name]:-}" ]] && continue
        [[ -z "$(ls -A "$d" 2>/dev/null)" ]] && _stale+=("$name")
    done
    if (( ${#_stale[@]} > 0 )); then
        echo "discover-mounts: ⚠ mountpoint(s) viejo(s) vacío(s) en custom/ (probable rename/remoción): ${_stale[*]}" >&2
        printf 'discover-mounts:   borralos (necesita sudo): sudo rmdir' >&2
        for s in "${_stale[@]}"; do printf ' %s/%s' "$CUSTOM_DIR" "$s" >&2; done
        printf '\n' >&2
    fi
fi

# gh keyring → archivo
# El keyring del SO (GNOME Keyring / KWallet) no es accesible dentro del
# container. Si el token está ahí, gh auth falla adentro aunque el host
# funcione. Migramos automáticamente a --insecure-storage (plaintext en
# hosts.yml) para que el bind mount lo exponga al container.
if command -v gh &>/dev/null && gh auth status 2>&1 | grep -q "(keyring)"; then
    echo "discover-mounts: gh token en keyring del SO — migrando a archivo..."
    TOKEN=$(gh auth token 2>/dev/null || true)
    if [ -n "$TOKEN" ]; then
        GH_HOST=$(gh auth status 2>&1 | awk '/Logged in to/{print $5; exit}')
        gh auth logout -h "${GH_HOST:-github.com}" 2>/dev/null || true
        echo "$TOKEN" | gh auth login -h "${GH_HOST:-github.com}" --with-token --insecure-storage
        echo "discover-mounts: gh migrado OK (token en ~/.config/gh/hosts.yml)."
    else
        echo "discover-mounts: WARN — no se pudo leer el token del keyring." >&2
    fi
fi
