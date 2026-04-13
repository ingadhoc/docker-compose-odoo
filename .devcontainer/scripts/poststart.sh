#!/bin/bash

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

# Odoo 19+ uses namespace packages (init.py). OLS needs __init__.py
[ -f /home/odoo/src/odoo/odoo/init.py ] && [ ! -f /home/odoo/src/odoo/odoo/__init__.py ] && \
    cp /home/odoo/src/odoo/odoo/init.py /home/odoo/src/odoo/odoo/__init__.py

# Generate OdooLS config (odools.toml)
ODOOLS="/home/odoo/custom/repositories/odools.toml"
paths=("/home/odoo/src/odoo/addons" "/home/odoo/src/odoo/odoo/addons" "/home/odoo/src/enterprise")
declare -A seen

# Custom repos first (priority)
for dir in /home/odoo/custom/repositories/*; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    [[ $name == .* || $name == src* || $name == tmp* ]] && continue
    find "$dir" -maxdepth 2 -name '__manifest__.py' -print -quit | grep -q . && { paths+=("$dir"); seen[$name]=1; }
done

# Src repos (skip if already in custom)
for dir in /home/odoo/src/repositories/*; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    [ -n "${seen[$name]:-}" ] && continue
    find "$dir" -maxdepth 2 -name '__manifest__.py' -print -quit | grep -q . && paths+=("$dir")
done

{
    echo '[[config]]'
    echo 'name = "default"'
    echo 'odoo_path = "/home/odoo/src/odoo"'
    echo 'python_path = "/home/odoo/venv/bin/python"'
    echo 'diag_missing_imports = "only_odoo"'
    echo 'addons_paths = ['
    for i in "${!paths[@]}"; do
        [ "$i" -lt $(( ${#paths[@]} - 1 )) ] && sep=',' || sep=''
        echo "    \"${paths[$i]}\"$sep"
    done
    echo ']'
} > "$ODOOLS"
echo "Generated $ODOOLS (${#paths[@]} paths)"

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
SKILL_PATH=".agents/"

# ingadhoc/skills — catálogo interno
INGADHOC_REPO="git@github.com:ingadhoc/skills.git"
INGADHOC_SKILLS=(
    "odoo-${ODOO_V}"
    "odoo-general"
    "odoo-code-review"
    "odoo-translator"
    "odoo-upgrade-migration"
    "odoo-test-from-commit"
    "odoo-test-from-video"
    "odoo-module-generator"
    "odoo-readme"
)

# Skills externas (formato "repo|skill"; el separador `|` evita colisionar
# con `:` presente en URLs SSH como git@github.com:org/repo.git)
EXTERNAL_SKILLS=(
    "anthropics/skills|skill-creator"
)

# Only install skills for Odoo 18 or 19
if [[ "$ODOO_V" != "18" && "$ODOO_V" != "19" ]]; then
    echo "No hay 'skills' disponibles para Odoo $ODOO_V. Saltando instalación."
else
    echo "Installing odoo skills in $PWD"
    LOG_FILE="$PWD/install_skill.log"
    install_failed=0

    # ingadhoc/skills
    SKILL_ARGS=()
    for skill in "${INGADHOC_SKILLS[@]}"; do
        SKILL_ARGS+=(--skill "$skill")
    done

    if ! CI=true npx --yes skills add "$INGADHOC_REPO" \
        "${SKILL_ARGS[@]}" \
        --agent github-copilot \
        --no-interactive \
        --yes > "$LOG_FILE" 2>&1; then
        install_failed=1
        echo "FALLO: error instalando skills de $INGADHOC_REPO"
    fi

    # External skills (formato "repo|skill")
    for entry in "${EXTERNAL_SKILLS[@]}"; do
        ext_repo="${entry%%|*}"
        ext_skill="${entry##*|}"
        if ! CI=true npx --yes skills add "$ext_repo" \
            --skill "$ext_skill" \
            --agent github-copilot \
            --no-interactive \
            --yes >> "$LOG_FILE" 2>&1; then
            install_failed=1
            echo "FALLO: error instalando skill '$ext_skill' desde $ext_repo"
        fi
    done

    if [ "$install_failed" -eq 0 ] && [ -d "$PWD/$SKILL_PATH" ]; then
        echo "Skills installed."
    else
        echo "FALLO: no se pudieron instalar las skills. Mostrando últimas líneas del log de instalación:"
        tail -n 200 "$LOG_FILE" || true
    fi

    rm "$LOG_FILE" || true
fi

if [[ "${AD_DEV_MODE:-}" == "MASTER" ]]; then
    echo "Running in master mode"
    ~/.resources/entrypoint
fi

exit 0
