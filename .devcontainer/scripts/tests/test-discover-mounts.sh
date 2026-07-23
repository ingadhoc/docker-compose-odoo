#!/usr/bin/env bash
# Test focal para el fix de R2_ENABLE_DEVOPS ~/.docker mount.
#
# Ejecuta discover-mounts.sh con un HOME temporal y verifica que el bind mount
# de ~/.docker apunte a /home/odoo/.docker-host (no a /home/odoo/.docker),
# evitando que VS Code Dev Containers falle al escribir su credential-helper.
#
# Uso: bash .devcontainer/scripts/tests/test-discover-mounts.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../discover-mounts.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

# Preparar un HOME temporal con .docker existente
mkdir -p "${TMP_HOME}/.docker"
echo '{}' > "${TMP_HOME}/.docker/config.json"

# Preparar .kube y .config/gcloud para que no sean omitidos
mkdir -p "${TMP_HOME}/.kube"
mkdir -p "${TMP_HOME}/.config/gcloud"

# Crear dirs dummy para todos los proyectos del catálogo que tienen git_url,
# para evitar que discover-mounts intente clonar durante el test.
mkdir -p "${TMP_HOME}/repositorios/devops"
mkdir -p "${TMP_HOME}/repositorios/devops-it"
mkdir -p "${TMP_HOME}/repositorios/adhoc-way"
mkdir -p "${TMP_HOME}/tuqui"
mkdir -p "${TMP_HOME}/repositorios/oba"
mkdir -p "${TMP_HOME}/repositorios/oba-project-memory"
mkdir -p "${TMP_HOME}/repositorios/odumbo"
mkdir -p "${TMP_HOME}/repositorios/consultoria-tecnica"

export HOME="$TMP_HOME"
export R2_ENABLE_DEVOPS=1

# El script escribe en REPO_ROOT; hacemos backup del archivo real si existe.
OUT="${REPO_ROOT}/docker-compose.auto-mounts.yml"
BACKUP="${TMP_HOME}/docker-compose.auto-mounts.yml.bak"
if [[ -f "$OUT" ]]; then
    cp "$OUT" "$BACKUP"
fi
restore() {
    if [[ -f "$BACKUP" ]]; then
        cp "$BACKUP" "$OUT"
    else
        rm -f "$OUT"
    fi
}
trap 'restore; rm -rf "$TMP_HOME"' EXIT

bash "$SCRIPT"

# Validaciones
docker_mount_line="$(grep -E '\.docker' "$OUT" || true)"
echo "--- docker mount line ---"
echo "$docker_mount_line"

if echo "$docker_mount_line" | grep -qE '/home/odoo/\.docker:ro'; then
    echo "FAIL: ~/.docker todavía se monta en /home/odoo/.docker (pisaría VS Code)"
    exit 1
fi

if ! echo "$docker_mount_line" | grep -qE '/home/odoo/\.docker-host:ro'; then
    echo "FAIL: ~/.docker no se monta en /home/odoo/.docker-host"
    exit 1
fi

echo "PASS: ~/.docker se monta en /home/odoo/.docker-host:ro (sin conflictos con VS Code)"
