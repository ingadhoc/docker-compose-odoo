#!/bin/bash

# ==============================
# Fix addons paths
echo "PostStart"
for app in "/home/odoo/custom/repositories/"*; do
    if [[ -d $app ]]; then
        app_name=$(basename $app)
        [[ $app_name == .* || $app_name == src* || $app_name == tmp* ]] && continue
        echo "App: $app_name"
        for module in "$app/"*; do
            if [[ -d $module ]]; then
                module_name=$(basename $module)
                [[ $module_name == .* || $module_name == src* ]] && continue
                echo "ln -sf $module/ /home/odoo/src/$module_name"
                if [ ! -L /home/odoo/src/$module_name ]; then
                    ln -sf $module/ /home/odoo/src/$module_name
                    echo "Creating symlink for $module_name ln -sf $module/ /home/odoo/src/$module_name"
                fi
            fi
        done
    fi
done

# Symlink to agents
PWD=$(pwd)
if [ -d ".github" ]; then
    sudo rm -rf ".github"
fi
sudo mkdir -p .github
sudo ln -sfn /agents .github

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
REPO_URL="git@github.com:unclecatvn/agent-skills.git"

echo "Installing skill $SKILL in $PWD"
LOG_FILE="$PWD/install_skill.log"

CI=true npx --yes skills add "$REPO_URL" \
    --skill "odoo-${ODOO_V}" \
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

if [[ "${AD_DEV_MODE:-}" == "MASTER" ]]; then
    echo "Running in master mode"
    ~/.resources/entrypoint
fi

exit 0
