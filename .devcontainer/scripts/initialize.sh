#!/usr/bin/env bash
# initialize.sh — el initializeCommand del devcontainer. Corre en el HOST,
# antes de `docker compose up`, cada vez que levantás el container.
#
# Dos pasos, en este orden y no en paralelo:
#   1. self-update.sh  — fast-forward del clone + pull de la imagen.
#   2. discover-mounts.sh — regenera docker-compose.auto-mounts.yml.
#
# El orden importa: el paso 1 puede traer una versión nueva de
# discover-mounts.sh, y queremos correr esa. La forma `object` de
# initializeCommand no sirve para esto — corre sus entradas en paralelo.
#
# discover-mounts queda al final para que su exit code siga siendo el del
# initializeCommand, como antes de que existiera este wrapper; self-update
# nunca falla (trata todo como warning), pero el `|| true` lo deja explícito.

# Las llaves, igual que en self-update.sh: el fast-forward del paso 1 puede
# reescribir este mismo archivo mientras bash lo lee. Así se parsea entero
# antes de ejecutar.
{
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/self-update.sh" || true
exec "${SCRIPT_DIR}/discover-mounts.sh"
}
