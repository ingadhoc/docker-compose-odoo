#!/bin/bash

echo "PostStart"

# Get Odoo version
adhoc_oba_version(){
    if [ -f "$HOME/ODOO_BY_ADHOC_VERSION" ]; then
        tr -d '\n' < "$HOME/ODOO_BY_ADHOC_VERSION" | cut -d. -f1
    fi
}

ODOO_V="$(adhoc_oba_version)"
if [ -z "${ODOO_V:-}" ]; then
    echo "FALLO: no se pudo inferir la versión de Odoo"
    exit 1
fi
echo "Odoo version: $ODOO_V"

# CLIs de agentes IA — idempotente (solo instala si no están presentes)
# Usa ~/.local para evitar permisos de root en /usr/local/lib/node_modules.
# Transitorio pre-bake: cuando oci-odoo-by-adhoc los incluya en la imagen dev,
# sacar este bloque y el mount del harness en devcontainer.json.
export npm_config_prefix="$HOME/.local"
install_cli_if_missing() {
    local cmd="$1" pkg="$2"
    if ! command -v "$cmd" &>/dev/null; then
        echo "Instalando $cmd ($pkg)..."
        npm install -g "$pkg" --quiet && echo "$cmd instalado." || echo "FALLO: no se pudo instalar $pkg"
    else
        echo "$cmd ya presente ($(command -v "$cmd"))."
    fi
}
install_cli_if_missing claude @anthropic-ai/claude-code
install_cli_if_missing codex @openai/codex
install_cli_if_missing gemini @google/gemini-cli

# gh CLI — binario directo (no está en npm). Transitorio pre-bake.
if ! command -v gh &>/dev/null; then
    echo "Instalando gh CLI..."
    GH_VERSION=$(curl -sf https://api.github.com/repos/cli/cli/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | sed 's/v//')
    if [ -n "$GH_VERSION" ]; then
        curl -sL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
            | tar xz -C /tmp && \
            mv "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" "$HOME/.local/bin/" && \
            echo "gh $GH_VERSION instalado." || echo "FALLO: no se pudo instalar gh"
    else
        echo "FALLO: no se pudo obtener la versión de gh desde GitHub API"
    fi
else
    echo "gh ya presente ($(command -v gh))."
fi

# Fix addons paths (symlinks)
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

# OdooLS config - only for Odoo 18+
if [ "$ODOO_V" -ge 18 ] 2>/dev/null; then
    echo "Configuring OdooLS for Odoo $ODOO_V"
    # Odoo 19+ uses namespace packages (init.py). OLS needs __init__.py
    [ -f /home/odoo/src/odoo/odoo/init.py ] && [ ! -f /home/odoo/src/odoo/odoo/__init__.py ] && \
        cp /home/odoo/src/odoo/odoo/init.py /home/odoo/src/odoo/odoo/__init__.py

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
else
    echo "OdooLS no soportado para Odoo $ODOO_V (requiere v18+). Saltando configuración."
fi

# Odoo skills installation - only for Odoo 18 or 19
SKILL="odoo-${ODOO_V}"
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

if [[ "$ODOO_V" != "18" && "$ODOO_V" != "19" ]]; then
    echo "No hay 'skills' disponibles para Odoo $ODOO_V. Saltando instalación."
else
    echo "Installing odoo skills in $PWD"
    LOG_FILE="$PWD/install_skill.log"
    install_failed=0

    # ingadhoc/skills — instalar para todos los agentes (paridad)
    SKILL_ARGS=()
    for skill in "${INGADHOC_SKILLS[@]}"; do
        SKILL_ARGS+=(--skill "$skill")
    done

    for agent in claude-code codex gemini-cli github-copilot; do
        if ! CI=true npx --yes skills add "$INGADHOC_REPO" \
            "${SKILL_ARGS[@]}" \
            --agent "$agent" \
            --no-interactive \
            --yes >> "$LOG_FILE" 2>&1; then
            install_failed=1
            echo "FALLO: error instalando skills de $INGADHOC_REPO para $agent"
        fi
    done

    # External skills (formato "repo|skill") — todos los agentes
    for entry in "${EXTERNAL_SKILLS[@]}"; do
        ext_repo="${entry%%|*}"
        ext_skill="${entry##*|}"
        for agent in claude-code codex gemini-cli github-copilot; do
            if ! CI=true npx --yes skills add "$ext_repo" \
                --skill "$ext_skill" \
                --agent "$agent" \
                --no-interactive \
                --yes >> "$LOG_FILE" 2>&1; then
                install_failed=1
                echo "FALLO: error instalando skill '$ext_skill' desde $ext_repo para $agent"
            fi
        done
    done

    if [ "$install_failed" -eq 0 ] && [ -d "$PWD/$SKILL_PATH" ]; then
        echo "Skills installed."
    else
        echo "FALLO: no se pudieron instalar las skills. Mostrando últimas líneas del log de instalación:"
        tail -n 200 "$LOG_FILE" || true
    fi

    rm "$LOG_FILE" || true
fi

# Capa Workspace — convenciones Adhoc adentro del container
# Requiere harness disponible en /home/odoo/.resources/harness/ (baked o via override-bind).
# Escribe /home/odoo/custom/.adhoc/ y bloque managed en .claude/CLAUDE.md, .codex/AGENTS.md, .gemini/GEMINI.md.
HARNESS_INSTALL="$HOME/.resources/harness/scripts/harness-install-user.sh"
if [ -x "$HARNESS_INSTALL" ]; then
    echo "Instalando capa Workspace desde $HARNESS_INSTALL"
    "$HARNESS_INSTALL" --target "$HOME" && echo "Capa Workspace OK."

    # Wrapper refresh-workspace para re-aplicar sin rebuild
    REFRESH_BIN="$HOME/.local/bin/refresh-workspace"
    cat > "$REFRESH_BIN" <<EOF
#!/bin/bash
exec "$HARNESS_INSTALL" --target "$HOME" "\$@"
EOF
    chmod +x "$REFRESH_BIN"
    echo "refresh-workspace disponible en $REFRESH_BIN"
else
    echo "AVISO: harness no disponible en $HOME/.resources/harness/ — capa Workspace no instalada."
    echo "  Para activarla: montar ~/odoo/harness via docker-compose.override.yml y hacer rebuild."
fi

# Workspace curado — contexto unificado para el dev y el agente IA
# Estructura: custom + oba-wiki/specs en raíz; odoo/* para odoo/enterprise/odoo-upgrade;
# repos OCA en oca/; todo deduplicado (custom tiene prioridad sobre baked).
build_workspace() {
    local WS="$HOME/workspace"
    local CUSTOM_REPOS="$HOME/custom/repositories"
    local SRC_REPOS="$HOME/src/repositories"
    local RESOURCES="$HOME/.resources"
    local CUSTOM="$HOME/custom"
    local SRC="$HOME/src"

    mkdir -p "$WS" "$WS/oca" "$WS/odoo"

    # .vscode: symlink al del workspace actual para que VS Code lo encuentre
    [[ -e "$WS/.vscode" ]] || ln -sf "$CUSTOM_REPOS/.vscode" "$WS/.vscode"

    # Rastrear repos en custom/repositories para deduplicar contra baked
    declare -A in_custom
    for repo in "$CUSTOM_REPOS"/*/; do
        [[ -d "$repo" ]] || continue
        name=$(basename "$repo")
        [[ $name == .* || $name == src || $name == tmp* ]] && continue
        in_custom[$name]=1
        [[ -e "$WS/$name" ]] || ln -sf "$repo" "$WS/$name"
    done

    # oba-wiki y oba-specs
    [[ -d "$RESOURCES/oba-wiki" && ! -e "$WS/oba-wiki" ]] && ln -sf "$RESOURCES/oba-wiki" "$WS/oba-wiki"
    [[ -d "$CUSTOM/oba-specs"  && ! -e "$WS/oba-specs"  ]] && ln -sf "$CUSTOM/oba-specs"  "$WS/oba-specs"

    # odoo/ — custom tiene prioridad sobre src (mismo patrón que 400-auto-detect-addons)
    local odoo_src enterprise_src
    odoo_src="$([[ -d $CUSTOM/odoo ]] && echo "$CUSTOM/odoo" || echo "$SRC/odoo")"
    enterprise_src="$([[ -d $CUSTOM/enterprise ]] && echo "$CUSTOM/enterprise" || echo "$SRC/enterprise")"
    [[ -d "$odoo_src"      && ! -e "$WS/odoo/odoo"        ]] && ln -sf "$odoo_src"      "$WS/odoo/odoo"
    [[ -d "$enterprise_src" && ! -e "$WS/odoo/enterprise"  ]] && ln -sf "$enterprise_src" "$WS/odoo/enterprise"
    [[ -d "$SRC/odoo-upgrade" && ! -e "$WS/odoo/odoo-upgrade" ]] && ln -sf "$SRC/odoo-upgrade" "$WS/odoo/odoo-upgrade"

    # Repos baked NOT en custom: oca-* → oca/, resto → raíz
    if [[ -d "$SRC_REPOS" ]]; then
        for repo in "$SRC_REPOS"/*/; do
            [[ -d "$repo" ]] || continue
            name=$(basename "$repo")
            [[ -n "${in_custom[$name]:-}" ]] && continue
            if [[ $name == oca-* ]]; then
                [[ -e "$WS/oca/$name" ]] || ln -sf "$repo" "$WS/oca/$name"
            else
                [[ -e "$WS/$name" ]] || ln -sf "$repo" "$WS/$name"
            fi
        done
    fi

    local root_count oca_count odoo_count
    root_count=$(find "$WS" -maxdepth 1 -mindepth 1 ! -name '.vscode' ! -name 'oca' ! -name 'odoo' | wc -l)
    oca_count=$(find "$WS/oca"  -maxdepth 1 -mindepth 1 | wc -l)
    odoo_count=$(find "$WS/odoo" -maxdepth 1 -mindepth 1 | wc -l)
    echo "Workspace construido en $WS ($root_count en raíz, $odoo_count en odoo/, $oca_count en oca/)"
}
build_workspace

# workspace-add / workspace-rm — comandos para traer/sacar repos del workspace bajo demanda
WORKSPACE_ADD="$HOME/.local/bin/workspace-add"
cat > "$WORKSPACE_ADD" <<'SCRIPT'
#!/bin/bash
set -e
name="${1:?Uso: workspace-add <repo-name>}"
WS="$HOME/workspace"
SRC_REPOS="$HOME/src/repositories"

# Buscar también en src/ directamente (ej. odoo, enterprise)
for candidate in "$SRC_REPOS/$name" "$HOME/src/$name"; do
    if [[ -d "$candidate" ]]; then
        if [[ $name == oca-* ]]; then
            target="$WS/oca/$name"
        else
            target="$WS/$name"
        fi
        if [[ -e "$target" ]]; then
            echo "Ya está en el workspace: $name"
        else
            ln -sf "$candidate" "$target"
            echo "Agregado: $target → $candidate"
        fi
        exit 0
    fi
done
echo "No encontrado: $name"
echo "Repos disponibles en src/repositories/:"
ls "$SRC_REPOS" 2>/dev/null
SCRIPT
chmod +x "$WORKSPACE_ADD"

WORKSPACE_RM="$HOME/.local/bin/workspace-rm"
cat > "$WORKSPACE_RM" <<'SCRIPT'
#!/bin/bash
set -e
name="${1:?Uso: workspace-rm <repo-name>}"
WS="$HOME/workspace"
CUSTOM_REPOS="$HOME/custom/repositories"

if [[ -d "$CUSTOM_REPOS/$name" ]]; then
    echo "Error: '$name' es un repo custom — no se puede remover del workspace."
    exit 1
fi

removed=0
for target in "$WS/$name" "$WS/oca/$name"; do
    if [[ -L "$target" ]]; then
        rm "$target"
        echo "Removido: $target"
        removed=1
    fi
done
[[ $removed -eq 0 ]] && echo "No encontrado en el workspace: $name"
SCRIPT
chmod +x "$WORKSPACE_RM"

echo "workspace-add y workspace-rm disponibles en $HOME/.local/bin/"

if [[ "${AD_DEV_MODE:-}" == "MASTER" ]]; then
    echo "Running in master mode"
    ~/.resources/entrypoint
fi

exit 0
