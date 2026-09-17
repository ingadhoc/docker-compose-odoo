#!/usr/bin/env bash
# Archivos que init.sh patchea por versión (DOMAIN, ODOO_VERSION, ODOO_PGHOST,
# paths de master, formatOnSave de las viejas) y después marca
# `--assume-unchanged` para que el patch no aparezca como cambio local.
#
# Fuente única: los lee init.sh para marcarlos y self-update.sh para no
# pisarlos con un fast-forward. Si acá falta uno, el self-update lo puede
# sobreescribir sin avisar.
#
# Paths relativos al root del repo.

MANAGED_FILES=(
    ".devcontainer/.vscode/launch.json"
    ".devcontainer/scripts/oncreate.sh"
    ".devcontainer/devcontainer.json"
    ".env"
    "docker-compose.yml"
)
