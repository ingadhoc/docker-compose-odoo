#!/bin/bash
set -euo pipefail

PY_SCRIPT="/home/odoo/.resources/entrypoint.d/400-auto-detect-addons"
ADDONS_CONF="/home/odoo/.resources/conf.d/10-addons.conf"
ODOO_CONF="/home/odoo/.config/odoo.conf"

"$PY_SCRIPT"
ADDONS_PATH_LINE=$(grep '^addons_path' "$ADDONS_CONF")

if grep -q '^addons_path' "$ODOO_CONF"; then
    sed -i "/^addons_path/c\\$ADDONS_PATH_LINE" "$ODOO_CONF"
else
    echo "$ADDONS_PATH_LINE" >> "$ODOO_CONF"
fi
