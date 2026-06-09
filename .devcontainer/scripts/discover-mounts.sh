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
# TOPOLOGÍA DECLARADA EN oba-project (trabajo C — spec adhoc-way
# `estandarizacion-oba.md` §4): el catálogo del ecosistema dejó de estar
# hardcodeado acá. Lo declara el hub del proyecto OBA en
# `oba-project/.adhoc/topology.yml`; este script conserva solo el MECANISMO
# (leer el manifest, detectar presencia en host, emitir los binds). El único
# path hardcodeado es el SEED: dónde está oba-project en el host (overridable
# por env OBA_PROJECT_HOST). Si el manifest no está, el catálogo queda vacío y
# el dev usa docker-compose.override.yml. Formato del manifest documentado en
# el propio topology.yml (schema regular, parseado por bash puro — sin yq).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${REPO_ROOT}/docker-compose.auto-mounts.yml"

# GCP legacy credentials: resolver cuenta activa antes de armar el catálogo.
_gcp_src=""
if command -v gcloud &>/dev/null; then
    _gcp_account="$(gcloud config get-value account 2>/dev/null || true)"
    if [[ -n "$_gcp_account" ]]; then
        _gcp_src="${HOME}/.config/gcloud/legacy_credentials/${_gcp_account}"
    fi
fi

# ── Catálogo de mounts: leído del manifest declarado en oba-project ──────────
# Seed mínimo (único path hardcodeado): dónde vive oba-project en el host.
# Override por env si tu clone está en otro lado.
OBA_PROJECT_HOST="${OBA_PROJECT_HOST:-${HOME}/repositorios/oba-project}"
TOPOLOGY_FILE="${OBA_PROJECT_HOST}/.adhoc/topology.yml"

PROJECTS=()

# _yval VALUE → trim + des-quote de un escalar YAML simple.
_yval() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"   # ltrim
    v="${v%"${v##*[![:space:]]}"}"   # rtrim
    if [[ ${#v} -ge 2 && "$v" == \"*\" ]]; then v="${v:1:${#v}-2}"; fi
    if [[ ${#v} -ge 2 && "$v" == \'*\' ]]; then v="${v:1:${#v}-2}"; fi
    printf '%s' "$v"
}

# _emit_project ID HOST TARGET REQ → expande ${HOME}/${REPO_ROOT} y push a PROJECTS.
_emit_project() {
    local id="$1" host="$2" target="$3" req="$4"
    [[ -z "$id" ]] && return 0
    host="${host//\$\{HOME\}/$HOME}";     host="${host//\$\{REPO_ROOT\}/$REPO_ROOT}"
    target="${target//\$\{HOME\}/$HOME}"; target="${target//\$\{REPO_ROOT\}/$REPO_ROOT}"
    # Entrada incompleta (falta host_path o container_target) → la salteo en vez
    # de emitir un bind inválido (`- /host:` o `- :/target`) que rompería compose.
    if [[ -z "$host" || -z "$target" ]]; then
        echo "discover-mounts: AVISO — entrada '$id' incompleta en el manifest (host_path/container_target vacío); la salteo." >&2
        return 0
    fi
    PROJECTS+=("${id}|${host}|${target}|${req}")
}

# Parser bash puro (corre en el host de cada dev — sin depender de yq). Schema
# regular: lista `mounts:` de entradas `- id:` con host_path/container_target/
# requires. Comentarios (#) y líneas en blanco se ignoran.
parse_topology() {
    local file="$1" line in_mounts=0
    local id="" host="" target="" req=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"          # ltrim
        [[ -z "$line" || "$line" == \#* ]] && continue    # blank / comentario
        if [[ "$line" == "mounts:"* ]]; then in_mounts=1; continue; fi
        [[ "$in_mounts" == 1 ]] || continue
        case "$line" in
            "- id:"*)             _emit_project "$id" "$host" "$target" "$req"
                                  id="$(_yval "${line#- id:}")"; host=""; target=""; req="" ;;
            "host_path:"*)        host="$(_yval "${line#host_path:}")" ;;
            "container_target:"*) target="$(_yval "${line#container_target:}")" ;;
            "requires:"*)         req="$(_yval "${line#requires:}")" ;;
        esac
    done < "$file"
    _emit_project "$id" "$host" "$target" "$req"          # flush último
}

if [[ -r "$TOPOLOGY_FILE" ]]; then
    parse_topology "$TOPOLOGY_FILE"
    echo "discover-mounts: catálogo leído de $TOPOLOGY_FILE (${#PROJECTS[@]} entradas)" >&2
else
    echo "discover-mounts: AVISO — no encontré $TOPOLOGY_FILE." >&2
    echo "discover-mounts:   oba-project es REQUERIDO para el workspace OBA (es el hub de specs/topología)." >&2
    echo "discover-mounts:   cloná oba-project en \$HOME/repositorios/oba-project (o seteá OBA_PROJECT_HOST)." >&2
    echo "discover-mounts:   El devcontainer igual levanta, pero sin mounts del ecosistema; para mounts" >&2
    echo "discover-mounts:   custom usá docker-compose.override.yml (opt-in)." >&2
fi

# GCP legacy credentials: mount runtime-específico (path computado del host),
# NO topología declarada → se agrega acá, no en el manifest.
[[ -n "$_gcp_src" ]] && PROJECTS+=("gcp-credentials|${_gcp_src}|/home/odoo/gcloud_legacy_credentials:ro|")

# Catálogo vacío (manifest ausente y sin GCP) → emitir salida mínima y salir,
# evitando expandir un array vacío bajo `set -u` en el engine de abajo.
if (( ${#PROJECTS[@]} == 0 )); then
    {
        echo "# docker-compose.auto-mounts.yml — AUTO-GENERATED por discover-mounts.sh"
        echo "# Catálogo vacío (sin $TOPOLOGY_FILE y sin GCP). Usá docker-compose.override.yml."
        echo ""
        echo "services:"
        echo "  odoo: {}"
    } > "$OUT"
    echo "discover-mounts: catálogo vacío → 0 mounts del ecosistema."
    exit 0
fi

declare -A PRESENT=()
declare -A SOURCES=()
declare -A TARGETS=()

for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r id host target req <<<"$entry"
    if [[ -d "$host" ]]; then
        PRESENT[$id]=1
        SOURCES[$id]="$host"
        TARGETS[$id]="$target"
    fi
done

# Chequeo de `requires`: pase ÚNICO, no transitivo. Mira presencia-en-host del
# parent (PRESENT[$req] del primer loop), no si el parent sobrevivió a su propio
# requires. Alcanza para cadenas de 1 nivel (el caso de hoy: todos `requires: ""`).
# Si algún día se arma una cadena `A→B→C`, esto necesita iterar hasta punto fijo.
for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r id host target req <<<"$entry"
    if [[ -n "$req" && -n "${PRESENT[$id]:-}" && -z "${PRESENT[$req]:-}" ]]; then
        unset "PRESENT[$id]"
        echo "discover-mounts: $id omitido (requiere $req mounteado)" >&2
    fi
done

detected=()
for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r id host target req <<<"$entry"
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
