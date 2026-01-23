#!/bin/bash

# Odoo skills installation
adhoc_oba_version(){
    if [ -f "$HOME/ODOO_BY_ADHOC_VERSION" ]; then
        tr -d '\n' < "$HOME/ODOO_BY_ADHOC_VERSION" | cut -d. -f1
    fi
}

file_ver="$(adhoc_oba_version)"

if [ -z "${file_ver:-}" ]; then
    echo "FALLO: no se pudo inferir la versión de Odoo"
    exit 1
fi

ODOO_V="$file_ver"
SKILL="odoo-${ODOO_V}"
SKILL_PATH=".agents/"
REPO_URL="https://github.com/unclecatvn/agent-skills.git"

# Only install skills for Odoo 18 or 19
if [[ "$ODOO_V" != "18" && "$ODOO_V" != "19" ]]; then
    echo "No hay 'skills' disponibles para Odoo $ODOO_V. Saltando instalación."
else
    echo "Installing skill $SKILL in $PWD"
    LOG_FILE="$PWD/install_skill.log"

    CI=true npx --yes skills add "$REPO_URL" \
        --skill "$SKILL" \
        --agent github-copilot \
        --no-interactive \
        --yes > "$LOG_FILE" 2>&1 || true

    if [ -d "$PWD/$SKILL_PATH" ]; then
        echo "Skill installed."
    else
        echo "FALLO: no se pudo instalar la skill '$SKILL'. Mostrando últimas líneas del log de instalación:"
        tail -n 200 "$LOG_FILE" || true
    fi

    rm "$LOG_FILE" || true
fi

if [[ "${AD_DEV_MODE:-}" == "MASTER" ]]; then
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
