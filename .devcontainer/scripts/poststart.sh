#!/bin/bash

if [[ "$AD_DEV_MODE" == "MASTER" ]]; then
    echo "Running in master mode"
    ~/.resources/entrypoint
fi

# Update addons paths in odools.toml from odoo.conf
ODOO_CONF="/home/odoo/.config/odoo.conf"
ODOOLS_TOML="/home/odoo/odools.toml"

if [[ -f "$ODOO_CONF" ]]; then
    ADDONS_PATH=$(grep "^addons_path" "$ODOO_CONF" | cut -d'=' -f2 | xargs)

    if [[ -n "$ADDONS_PATH" && -f "$ODOOLS_TOML" ]]; then
        # Convert comma-separated paths to array format
        ARRAY_PATHS=$(echo "$ADDONS_PATH" | sed 's/,/","/g' | sed 's/^/["/' | sed 's/$/"]/')
        # Create temp file to avoid device busy error on mounted file
        TEMP_FILE=$(mktemp)
        sed "s|^addons_paths.*|addons_paths = $ARRAY_PATHS|" "$ODOOLS_TOML" > "$TEMP_FILE"
        cp "$TEMP_FILE" "$ODOOLS_TOML"
        rm "$TEMP_FILE"
    fi
fi

exit 0
