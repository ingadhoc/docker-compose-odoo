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
# Catálogo embebido más abajo. Cada entry declara:
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${REPO_ROOT}/docker-compose.auto-mounts.yml"

PROJECTS=(
    "devops|${HOME}/repositorios/devops|/home/odoo/custom/devops|"
    "adhoc-way|${HOME}/repositorios/adhoc-way|/home/odoo/custom/adhoc-way|"
    "tuqui|${HOME}/tuqui|/home/odoo/custom/tuqui|"
    # Self-mount del propio docker-compose-odoo deshabilitado (mayo 2026):
    # cuando devops ya está mounteado, el bind anidado en
    # custom/devops/docker-compose-odoo aparece como dir dummy en lugar del
    # contenido real del repo host. Revisar más adelante — probablemente
    # con flag opt-in en lugar de auto, o cambiando el target fuera de
    # custom/devops/ para evitar el bind anidado.
    # "docker-compose-odoo|${REPO_ROOT}|/home/odoo/custom/devops/docker-compose-odoo|devops"
)

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

{
    echo "# docker-compose.auto-mounts.yml — AUTO-GENERATED por"
    echo "# .devcontainer/scripts/discover-mounts.sh (initializeCommand)."
    echo "# NO EDITAR A MANO: cambios se pierden en el próximo rebuild."
    echo "# Para mounts custom (path no-default) usá docker-compose.override.yml."
    echo "#"
    if (( ${#detected[@]} == 0 )); then
        echo "# Proyectos detectados: ninguno."
        echo ""
        echo "services:"
        echo "  odoo: {}"
    else
        echo "# Proyectos detectados:"
        for id in "${detected[@]}"; do
            echo "#   $id  (${SOURCES[$id]} → ${TARGETS[$id]})"
        done
        echo ""
        echo "services:"
        echo "  odoo:"
        echo "    volumes:"
        for id in "${detected[@]}"; do
            echo "      - ${SOURCES[$id]}:${TARGETS[$id]}"
        done
    fi
} > "$OUT"

if (( ${#detected[@]} == 0 )); then
    echo "discover-mounts: 0 proyectos del ecosistema detectados en host"
else
    echo "discover-mounts: ${#detected[@]} proyecto(s) detectado(s) → ${detected[*]}"
fi
