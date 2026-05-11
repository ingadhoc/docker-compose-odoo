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

# Limpieza de artefactos de versiones anteriores del setup
rm -rf "$HOME/workspace"                                                   # viejo workspace dir
rm -rf "$HOME/custom/.claude" "$HOME/custom/.agents"                      # skills instaladas en custom/ por error
rm -rf "$HOME/custom/.codex" "$HOME/custom/.gemini"
rm -f  "$HOME/custom/skills-lock.json"

# Overlay src/ dentro de custom/ — symlinks a repos baked de la imagen.
# Los symlinks apuntan a paths internos del container; son válidos solo adentro.
# Regla de dedup: si custom/<name> existe (repo local o symlink al host), no se monta en src/.
# Se rebuild completo en cada postCreate para limpiar symlinks stale.
build_workspace() {
    local CUSTOM="$HOME/custom"
    local CUSTOM_REPOS="$CUSTOM/repositories"
    local SRC="$HOME/src"

    # Rebuild desde cero; limpiar también adhoc/ de instalaciones anteriores
    rm -rf "$CUSTOM/src" "$CUSTOM/adhoc"
    mkdir -p "$CUSTOM/src"

    # Rastrear repos en custom/repositories para dedup de src/repositories/
    declare -A in_custom
    for repo in "$CUSTOM_REPOS"/*/; do
        [[ -d "$repo" ]] || continue
        name=$(basename "$repo")
        [[ $name == .* || $name == src || $name == tmp* ]] && continue
        in_custom[$name]=1
    done

    # Repos en custom/ fuera de repositories/ y src/ (clonados directo:
    # adhoc-way, oba-wiki, oba-specs, ingadhoc-skills, etc., y también
    # overrides de baked como odoo/ o enterprise/ si el dev los clona).
    # Se listan dinámicos en AGENTS.md para reflejar qué clonó cada dev.
    declare -A custom_others
    for d in "$CUSTOM"/*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        [[ $name == .* || $name == repositories || $name == src || $name == adhoc || $name == tmp* ]] && continue
        custom_others[$name]=1
    done

    # src/ — espejo de /home/odoo/src/: solo repos con .git, deduplicados contra custom/
    local src_count=0
    for item in "$SRC"/*/; do
        [[ -d "$item" ]] || continue
        name=$(basename "$item")
        [[ $name == repositories ]] && continue       # se maneja separado
        [[ ! -d "$item/.git" ]] && continue           # omitir módulos sueltos sin repo git
        [[ -n "${in_custom[$name]:-}" || -d "$CUSTOM/$name" ]] && continue  # ya en custom/
        ln -sf "$item" "$CUSTOM/src/$name"
        (( src_count++ )) || true
    done

    # src/repositories/ — repos baked no en custom/repositories/
    local repo_count=0
    if [[ -d "$SRC/repositories" ]]; then
        mkdir -p "$CUSTOM/src/repositories"
        for repo in "$SRC/repositories"/*/; do
            [[ -d "$repo" ]] || continue
            name=$(basename "$repo")
            [[ -n "${in_custom[$name]:-}" ]] && continue
            ln -sf "$repo" "$CUSTOM/src/repositories/$name"
            (( repo_count++ )) || true
        done
    fi

    # AGENTS.md dinámico + CLAUDE.md/GEMINI.md (estándar adhoc-way)
    {
        cat <<'HEADER'
# Workspace OBA

Iniciá `claude`, `codex` o `gemini` desde `/home/odoo/custom/` para trabajo cross-repo.
Para bugs acotados a un módulo podés iniciar desde ese repo directamente.

## Estructura

- **`repositories/`:** repos del dev con módulos Odoo (editables, branch activa).
- **Otros repos clonados directo en `custom/`:** repos del ecosistema (`adhoc-way`, `oba-wiki`, `oba-specs`, `ingadhoc-skills`, etc.) y/o overrides de baked (`odoo`, `enterprise`). Listado efectivo abajo.
- **`src/`:** repos baked de la imagen no presentes en `custom/` (referencia, symlinks de container).
  - `src/repositories/`: repos baked no en `repositories/`.

## Repos en custom/ (fuera de repositories/ y src/)

HEADER
        if [[ ${#custom_others[@]} -eq 0 ]]; then
            echo "_Ninguno todavía._"
        else
            for name in $(echo "${!custom_others[@]}" | tr ' ' '\n' | sort); do
                echo "- \`$name\`"
            done
        fi
        cat <<'MIDDLE'

## Repos del dev en repositories/

MIDDLE
        if [[ ${#in_custom[@]} -eq 0 ]]; then
            echo "_Ningún repo de módulos clonado todavía._"
        else
            for name in $(echo "${!in_custom[@]}" | tr ' ' '\n' | sort); do
                echo "- \`$name\`"
            done
        fi
        cat <<'FOOTER'

## Cómo navegar

- **Wiki del módulo:** `oba-wiki/wiki/19/<categoría>/<producto>/<módulo>.md` (en `custom/` o `src/`)
- **Convenciones Adhoc:** en `~/.claude/CLAUDE.md` (cargado globalmente).
- **Traer repo baked al workspace:** `workspace-add <nombre>`
- **Sacarlo:** `workspace-rm <nombre>`
FOOTER
    } > "$CUSTOM/AGENTS.md"

    cat > "$CUSTOM/CLAUDE.md" <<'EOF'
# CLAUDE.md
Ver **[`AGENTS.md`](./AGENTS.md)** — fuente canónica de instrucciones para este workspace.
EOF
    cat > "$CUSTOM/GEMINI.md" <<'EOF'
# GEMINI.md
Ver **[`AGENTS.md`](./AGENTS.md)** — fuente canónica de instrucciones para este workspace.
EOF

    echo "Overlay construido: custom/src/ ($src_count repos directos, $repo_count en repositories/)"
}
build_workspace

# workspace-add / workspace-rm — comandos para traer/sacar repos de src/ bajo demanda
WORKSPACE_ADD="$HOME/.local/bin/workspace-add"
cat > "$WORKSPACE_ADD" <<'SCRIPT'
#!/bin/bash
set -e
name="${1:?Uso: workspace-add <repo-name>}"
CUSTOM="$HOME/custom"
SRC="$HOME/src"

if [[ -d "$SRC/$name" ]]; then
    candidate="$SRC/$name"
    target="$CUSTOM/src/$name"
elif [[ -d "$SRC/repositories/$name" ]]; then
    mkdir -p "$CUSTOM/src/repositories"
    candidate="$SRC/repositories/$name"
    target="$CUSTOM/src/repositories/$name"
else
    echo "No encontrado: $name"
    echo "Repos en src/: $(ls "$SRC" 2>/dev/null | tr '\n' ' ')"
    echo "Repos en src/repositories/: $(ls "$SRC/repositories" 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

if [[ -e "$target" ]]; then
    echo "Ya está: $name"
else
    ln -sf "$candidate" "$target"
    echo "Agregado: $target"
fi
SCRIPT
chmod +x "$WORKSPACE_ADD"

WORKSPACE_RM="$HOME/.local/bin/workspace-rm"
cat > "$WORKSPACE_RM" <<'SCRIPT'
#!/bin/bash
set -e
name="${1:?Uso: workspace-rm <repo-name>}"
CUSTOM="$HOME/custom"

if [[ -d "$CUSTOM/repositories/$name" ]]; then
    echo "Error: '$name' es un repo del dev — no se puede remover."
    exit 1
fi

removed=0
for target in "$CUSTOM/src/$name" "$CUSTOM/src/repositories/$name" "$CUSTOM/adhoc/$name"; do
    if [[ -L "$target" ]]; then
        rm "$target"
        echo "Removido: $target"
        removed=1
    fi
done
[[ $removed -eq 0 ]] && echo "No encontrado en src/: $name"
SCRIPT
chmod +x "$WORKSPACE_RM"

echo "workspace-add y workspace-rm disponibles en $HOME/.local/bin/"

# CLIs de agentes IA — idempotente (solo instala si no están presentes)
# Usa ~/.local para evitar permisos de root en /usr/local/lib/node_modules.
# Transitorio pre-bake: cuando oci-odoo-by-adhoc los incluya en la imagen dev, sacar este bloque.
export npm_config_prefix="$HOME/.local"

# Node 20+ — requerido por OpenCode v1.14+, Gemini CLI y claude-code v2.
# User-local (N_PREFIX) para no requerir sudo, consistente con el patrón del bloque.
# Transitorio pre-bake OCI: cuando la imagen dev traiga Node 20, sacar este bloque.
export N_PREFIX="$HOME/.local"
if ! command -v n &>/dev/null; then
    echo "Instalando n (manager de Node)..."
    npm install -g n --quiet && echo "n instalado." || echo "FALLO: no se pudo instalar n"
fi
if command -v n &>/dev/null; then
    n 20 >/dev/null && echo "Node $(node -v) activo." || echo "FALLO: no se pudo activar Node 20"
    hash -r
fi

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
# OpenCode (sst/opencode) — runtime CLI alternativo a Claude Code y Codex.
# Se mantiene en el devcontainer para que el dev pueda elegir agente.
# Transitorio pre-bake OCI: cuando se baje al bake de la imagen dev, sacar de acá.
install_cli_if_missing opencode opencode-ai

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

# Extras CLI (jq, ripgrep, bat) — calidad de vida para workflow con agentes.
# Solo en imagen dev. Transitorio pre-bake OCI: cuando dev.packages los traiga,
# sacar este bloque.
CLI_EXTRAS=(jq ripgrep bat)
extras_missing=()
for pkg in "${CLI_EXTRAS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || extras_missing+=("$pkg")
done
if [ "${#extras_missing[@]}" -gt 0 ]; then
    echo "Instalando extras CLI: ${extras_missing[*]}"
    sudo apt-get -qq update \
        && sudo apt-get -qq install -y --no-install-recommends "${extras_missing[@]}" \
        && echo "Extras CLI instalados." \
        || echo "FALLO: no se pudieron instalar ${extras_missing[*]}"
else
    echo "Extras CLI ya presentes (${CLI_EXTRAS[*]})."
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
    # Odoo dev core
    "odoo-${ODOO_V}"
    "odoo-general"
    "odoo-review"               # antes: odoo-code-review (rota silenciosa)
    "odoo-translator"
    "odoo-upgrade-migration"
    "odoo-test-from-commit"
    "odoo-test-from-video"
    "odoo-module-generator"
    "odoo-auto-readme"          # antes: odoo-readme (rota silenciosa)
    "odoo-commit-explainer"     # mensajes de commit Odoo-style
    "odoo-video-to-docs"        # docs desde video — alto uso real (Academy)
    # SDD / specs
    "product-sdd"
    # Universales del ecosistema
    "adhoc-way-bootstrap"       # bootstrap de repo nuevo con patrón adhoc-way
    "adhoc-pr-flow"             # detecta caso PR (4 casos post-ADR 0014) y ejecuta
)

# Skills externas (formato "repo|skill"; el separador `|` evita colisionar
# con `:` presente en URLs SSH como git@github.com:org/repo.git)
EXTERNAL_SKILLS=(
    "anthropics/skills|skill-creator"
    "vercel-labs/skills|find-skills"      # descubrimiento de skills, recomendado por ingadhoc/skills
)

if [[ "$ODOO_V" != "18" && "$ODOO_V" != "19" ]]; then
    echo "No hay 'skills' disponibles para Odoo $ODOO_V. Saltando instalación."
else
    # Skills se instalan desde $HOME → van a ~/.claude/skills/, ~/.agents/skills/, etc. (globales, persistidos)
    cd "$HOME"
    echo "Installing odoo skills in $PWD"
    LOG_FILE="$PWD/install_skill.log"
    install_failed=0

    # Validación pre-install: confirmar que cada skill de INGADHOC_SKILLS exista
    # en el catálogo vivo. Cuando se modifica el catálogo (rename, move) y este
    # array no se sincroniza, npx skills add falla silencioso. El script
    # validate-skill-list.sh del propio catálogo detecta el drift loud.
    # Origen: adhoc-way spec 0014 (política-skills-y-flujo-contributor), Eje 2.
    VALIDATE_DIR=$(mktemp -d)
    if git clone --quiet --depth=1 git@github.com:ingadhoc/skills.git "$VALIDATE_DIR" 2>/dev/null; then
        if ! bash "$VALIDATE_DIR/scripts/validate-skill-list.sh" "${INGADHOC_SKILLS[@]}"; then
            echo "FALLO: validación de INGADHOC_SKILLS contra catálogo. Revisá nombres en este script." >&2
            install_failed=1
        fi
        rm -rf "$VALIDATE_DIR"
    else
        echo "WARN: no pude clonar ingadhoc/skills para validar la lista — sigo sin validación."
        rm -rf "$VALIDATE_DIR"
    fi

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

# Convenciones Adhoc adentro del container — capa Usuario + capa Workspace.
# Requiere adhoc-way clonado en data/custom/ingadhoc-adhoc-way/ (convención de
# prefijo ingadhoc- para repos de la org).
# - Capa Usuario  (--target $HOME): bloque managed en ~/.claude/CLAUDE.md,
#   ~/.codex/AGENTS.md, ~/.gemini/GEMINI.md y ~/.adhoc/conventions.md.
# - Capa Workspace (--target $HOME/custom --workspace-block-only): bloque
#   managed con reglas operativas (uso de tuqui, skills, path /home/odoo/shared)
#   inyectado al final del AGENTS.md que generó build_workspace. NO toca
#   .claude/.codex/.gemini/.adhoc/ en custom/ (esos no deben existir ahí).
#   Spec 0012 Eje 3.
ADHOC_WAY_INSTALL="$HOME/custom/ingadhoc-adhoc-way/scripts/adhoc-way-install-user.sh"
if [ -x "$ADHOC_WAY_INSTALL" ]; then
    echo "Instalando capa Usuario desde $ADHOC_WAY_INSTALL (target=\$HOME)"
    "$ADHOC_WAY_INSTALL" --target "$HOME" && echo "Capa Usuario OK."

    echo "Aplicando bloque de capa Workspace en custom/AGENTS.md"
    "$ADHOC_WAY_INSTALL" --target "$HOME/custom" --workspace-block-only \
        && echo "Capa Workspace OK." \
        || echo "AVISO: capa Workspace falló (script viejo? requiere flag --workspace-block-only)."

    # Wrapper refresh-workspace para re-aplicar ambas capas sin rebuild
    REFRESH_BIN="$HOME/.local/bin/refresh-workspace"
    cat > "$REFRESH_BIN" <<EOF
#!/bin/bash
set -e
"$ADHOC_WAY_INSTALL" --target "\$HOME" "\$@"
"$ADHOC_WAY_INSTALL" --target "\$HOME/custom" --workspace-block-only "\$@"
EOF
    chmod +x "$REFRESH_BIN"
    echo "refresh-workspace disponible en $REFRESH_BIN"
else
    echo "AVISO: adhoc-way no disponible en custom/ingadhoc-adhoc-way/ — capa Usuario/Workspace no instaladas."
    echo "  Para activarlas: clonar git@github.com:ingadhoc/adhoc-way en data/custom/ingadhoc-adhoc-way."
fi

# Allow-list base de Claude Code (operaciones read-only) — reduce prompts
# durante demos / análisis. Idempotente: solo escribe si no existe el archivo.
# Si el dev tiene un settings.json propio, lo respeta.
# A futuro esto se promueve al template managed de adhoc-way (item ROADMAP).
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [ ! -f "$CLAUDE_SETTINGS" ]; then
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
    cat > "$CLAUDE_SETTINGS" <<'JSON'
{
  "permissions": {
    "allow": [
      "Read",
      "Glob",
      "Grep",
      "Bash(ls:*)",
      "Bash(find:*)",
      "Bash(cat:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(wc:*)",
      "Bash(grep:*)",
      "Bash(rg:*)",
      "Bash(tree:*)",
      "Bash(file:*)",
      "Bash(stat:*)",
      "Bash(pwd)",
      "Bash(git status:*)",
      "Bash(git log:*)",
      "Bash(git diff:*)",
      "Bash(git show:*)",
      "Bash(git branch:*)",
      "Bash(git remote:*)",
      "Bash(git ls-files:*)",
      "Bash(git blame:*)",
      "Bash(git rev-parse:*)",
      "Bash(git stash list:*)",
      "Bash(git describe:*)",
      "Bash(git worktree list:*)",
      "Bash(git reflog:*)",
      "Bash(git ls-tree:*)",
      "Bash(git cat-file:*)",
      "Bash(git for-each-ref:*)",
      "Bash(git -C *)",
      "mcp__Tuqui__odoo_search_read",
      "mcp__Tuqui__odoo_read_group",
      "mcp__Tuqui__odoo_models_list",
      "mcp__Tuqui__odoo_search_count",
      "mcp__Tuqui__odoo_fields_get",
      "mcp__Tuqui__odoo_fields_batch",
      "mcp__Tuqui__odoo_schema_discover",
      "mcp__Tuqui__odoo_skills_directory",
      "mcp__Tuqui__odoo_skill_detail",
      "mcp__Tuqui__tuqui_context",
      "mcp__Tuqui__tuqui_guide"
    ]
  }
}
JSON
    echo "Allow-list base de Claude Code instalada en $CLAUDE_SETTINGS"
else
    echo "Claude Code settings.json ya existe — respeto config propia ($CLAUDE_SETTINGS)"
fi

if [[ "${AD_DEV_MODE:-}" == "MASTER" ]]; then
    echo "Running in master mode"
    ~/.resources/entrypoint
fi

exit 0
