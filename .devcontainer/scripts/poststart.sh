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
    # Excluye los contextos *-ctx — esos se listan en sección router aparte.
    declare -A custom_others
    for d in "$CUSTOM"/*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        [[ $name == .* || $name == repositories || $name == src || $name == adhoc || $name == tmp* ]] && continue
        [[ $name == *-ctx ]] && continue
        custom_others[$name]=1
    done

    # Contextos (folders *-ctx) — detección "custom gana, src fallback".
    # Pattern documentado en T-67744: el agente IA detecta qué contextos
    # están disponibles y a qué path apuntan. El dev NO ve el contexto en
    # su workspace (no se symlinkea al top-level) salvo que lo clone
    # explícito en custom/. Si el contexto solo existe en src/ (baked en la
    # imagen), el path en el router apunta directo a src/<X-ctx>/.
    declare -A contexts
    for item in "$CUSTOM"/*-ctx/; do
        [[ -d "$item" ]] || continue
        name=$(basename "$item")
        contexts[$name]="${item%/}"
    done
    for item in "$SRC"/*-ctx/; do
        [[ -d "$item" ]] || continue
        name=$(basename "$item")
        [[ -n "${contexts[$name]:-}" ]] && continue
        contexts[$name]="${item%/}"
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
        cat <<'INTRO'
# Workspace OBA

Iniciá `claude`, `codex` o `gemini` desde `/home/odoo/custom/` para trabajo cross-repo.
Para bugs acotados a un módulo podés iniciar desde ese repo directamente.

## Modos de trabajo (router de contextos)

Al pararte acá con un agente IA, elegí el modo según el tema. Los contextos se detectan automáticamente — `custom/<X-ctx>/` (clonado por el dev) gana sobre `/home/odoo/src/<X-ctx>/` (baked en la imagen). El dev no ve el contexto en su workspace salvo que lo clone explícito; el agente sí sabe que existe via este listado.

INTRO
        if [[ ${#contexts[@]} -eq 0 ]]; then
            echo "_Sin contextos detectados todavía._"
        else
            for name in $(echo "${!contexts[@]}" | tr ' ' '\n' | sort); do
                path="${contexts[$name]}"
                base="${name%-ctx}"
                case "$name" in
                    adhoc-way-ctx)
                        desc="onboarding al patrón adhoc-way, convenciones del ecosistema, specs, ADRs (subdirs: adhoc-way, oba-wiki)"
                        ;;
                    devops-ctx)
                        desc="tareas DevOps: k8s/Pulumi, charts Helm, OCI bake, herramientas internas"
                        ;;
                    *)
                        desc=""
                        ;;
                esac
                if [[ -n "$desc" ]]; then
                    echo "- **$base** ($desc): \`$path/\`"
                else
                    echo "- **$base**: \`$path/\`"
                fi
            done
        fi
        cat <<'STRUCT'

**Default** (sin contexto explícito): módulos OBA, tareas Tuqui, debugging Odoo. Seguir lo que sigue en este AGENTS.md.

## Estructura

- **`repositories/`:** repos del dev con módulos Odoo (editables, branch activa).
- **Otros repos clonados directo en `custom/`:** repos del ecosistema (`adhoc-way`, `oba-wiki`, `oba-specs`, `ingadhoc-skills`, etc.) y/o overrides de baked (`odoo`, `enterprise`). Listado efectivo abajo.
- **`src/`:** repos baked de la imagen no presentes en `custom/` (referencia, symlinks de container).
  - `src/repositories/`: repos baked no en `repositories/`.

## Repos en custom/ (fuera de repositories/ y src/)

STRUCT
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

# Compartir sesiones de Claude Code host↔container.
# Delegado al script standalone para que postStartCommand también pueda
# correrlo (en cada start del container, no solo en postCreate como
# poststart.sh) y captar proyectos nuevos del host sin necesidad de
# rebuild. Detalle de la lógica en share-claude-sessions.sh.
/scripts/share-claude-sessions.sh || true

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
# Busca adhoc-way con resolución "custom gana, src fallback":
#   1. custom/adhoc-way-ctx/adhoc-way/  ← layout actual con contextos
#   2. custom/ingadhoc-adhoc-way/       ← layout legacy (prefijo ingadhoc-)
#   3. src/adhoc-way-ctx/adhoc-way/     ← baked en imagen dev (default)
# - Capa Usuario  (--target $HOME): bloque managed en ~/.claude/CLAUDE.md,
#   ~/.codex/AGENTS.md, ~/.gemini/GEMINI.md y ~/.adhoc/conventions.md.
# - Capa Workspace (--target $HOME/custom --workspace-block-only): bloque
#   managed con reglas operativas (uso de tuqui, skills, path /home/odoo/shared)
#   inyectado al final del AGENTS.md que generó build_workspace. NO toca
#   .claude/.codex/.gemini/.adhoc/ en custom/ (esos no deben existir ahí).
#   Spec 0012 Eje 3.
ADHOC_WAY_INSTALL=""
for candidate in \
    "$HOME/custom/adhoc-way-ctx/adhoc-way/scripts/adhoc-way-install-user.sh" \
    "$HOME/custom/ingadhoc-adhoc-way/scripts/adhoc-way-install-user.sh" \
    "$HOME/src/adhoc-way-ctx/adhoc-way/scripts/adhoc-way-install-user.sh" ; do
    if [ -x "$candidate" ]; then
        ADHOC_WAY_INSTALL="$candidate"
        break
    fi
done

if [ -n "$ADHOC_WAY_INSTALL" ]; then
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
    echo "AVISO: adhoc-way no encontrado — capa Usuario/Workspace no instaladas."
    echo "  Buscado en: custom/adhoc-way-ctx/adhoc-way/, custom/ingadhoc-adhoc-way/, src/adhoc-way-ctx/adhoc-way/."
fi

# Contextos opcionales `custom/<scope>-ctx/` — patrón generalizado
# (ingadhoc/adhoc-way#62 spec madre `contextos-opcionales-en-custom.md`).
#
# `ensure_ctx_clones` es helper genérico: detecta team key en
# ~/.adhoc/teams, crea custom/<ctx_name>/, y clona/fetcha la lista de
# repos pasada como argumento. Idempotente: clone si falta, fetch si está.
#
# Cada bundle tiene su `init_<scope>_ctx` que define la lista de repos y
# escribe el AGENTS.md + README.md con contenido específico.
#
# Bundles soportados hoy:
# - devops-ctx (team key `devops`) — spec en ingadhoc/devops-specs (PR #6).
# - adhoc-way-ctx (team key `adhoc-way`) — spec en ingadhoc/adhoc-way#62.
# - tuqui-ctx (team key `tuqui`) — pendiente validación team Tuqui (spec
#   en ingadhoc/adhoc-way#62, sección `tuqui-ctx.md`).
ensure_ctx_clones() {
    local team_key="$1"
    local ctx_name="$2"
    shift 2
    # remaining args: entries "name|url" (branch siempre main por default)

    local teams_file="$HOME/.adhoc/teams"
    if [ ! -f "$teams_file" ] || ! grep -q "^${team_key}$" "$teams_file"; then
        return 1
    fi
    echo "Team ${team_key} detectado en ${teams_file} — inicializando custom/${ctx_name}/"

    local ctx_dir="$HOME/custom/${ctx_name}"
    mkdir -p "$ctx_dir"

    local count=0
    for entry in "$@"; do
        local repo_name="${entry%%|*}"
        local repo_url="${entry##*|}"
        local dest="$ctx_dir/$repo_name"
        if [ ! -d "$dest/.git" ]; then
            echo "  Clonando $repo_name..."
            git clone --depth=20 "$repo_url" "$dest" 2>&1 | tail -1 || \
                echo "  AVISO: clone $repo_name falló (sin auth GitHub? skipping)"
        else
            (cd "$dest" && git fetch --quiet origin 2>/dev/null) || \
                echo "  AVISO: fetch $repo_name falló (skipping)"
        fi
        count=$((count + 1))
    done

    echo "  custom/${ctx_name}/ OK (${count} repos default)."
    return 0
}

# Activa devops-ctx cuando ~/.adhoc/teams contiene `devops`.
# Spec: ingadhoc/devops-specs `specs/10_draft/devops-workspace-context.md`.
init_devops_ctx() {
    # Repos default (6) — 5 infra core + devops-specs.
    local -a repos=(
        "oci-odoo-by-adhoc|git@github.com:adhoc-cicd/oci-odoo-by-adhoc.git"
        "helm-charts|git@github.com:adhoc-dev/helm-charts.git"
        "devops-cloud-infra|git@github.com:ingadhoc/devops-cloud-infra.git"
        "devops-ops-tools|git@github.com:ingadhoc/devops-ops-tools.git"
        "pylib_odoo_saas|git@github.com:ingadhoc/pylib_odoo_saas.git"
        "devops-specs|git@github.com:ingadhoc/devops-specs.git"
    )
    ensure_ctx_clones "devops" "devops-ctx" "${repos[@]}" || return 0

    local devops_ctx="$HOME/custom/devops-ctx"

    # Mini-wiki (Eje 3) — regenerado en cada poststart.
    cat > "$devops_ctx/AGENTS.md" <<'AGENTS_MD'
# DevOps context — stack Adhoc

Activado automáticamente por `poststart.sh` cuando `~/.adhoc/teams`
contiene `devops`. Spec madre:
`devops-specs/specs/10_draft/devops-workspace-context.md`.

## Cuándo iniciar Claude acá vs en `custom/`

- **DevOps puro** (infra, seguridad, k8s, Pulumi, Helm, OCI bake, IaC):
  iniciar desde `custom/devops-ctx/`. Carga este `AGENTS.md` primero
  → el agente arranca con contexto del stack en vez de pegárselo cada
  vez.
- **DevOps ↔ Odoo** (módulo `saas_k8s`, bake de versión nueva que toca
  addons, helm chart que consume un módulo, debugging end-to-end):
  iniciar desde `custom/`. Carga el `AGENTS.md` del workspace OBA con
  las reglas cross-repo + lista de addons + reglas Tuqui.
- **Editar specs / ADRs del team:** iniciar desde
  `custom/devops-ctx/devops-specs/`.

## Repos en este folder

- `oci-odoo-by-adhoc` (`adhoc-cicd/`) — bake de la imagen Odoo by Adhoc.
  Stages `os-base` → `prod` → `dev`. PR workflow: `branch + PR same-repo`
  en `adhoc-cicd/`. Tags `.next` para builds de prueba.
- `helm-charts` (`adhoc-dev/`) — charts Helm del stack: DB (CNPG), Odoo,
  jobs de instalación / mantenimiento, certs SSL, ingress.
- `devops-cloud-infra` (`ingadhoc/`) — IaC en Pulumi del cluster k8s
  **nuevo** (en migración). Convive con el cluster legacy `adhocprod`.
- `devops-ops-tools` (`ingadhoc/`) — otras imágenes que mantenemos
  (no-Odoo).
- `pylib_odoo_saas` (`ingadhoc/`) — librería Python con helpers que el
  módulo Odoo `saas_k8s` consume para hacer ABM en los clusters.
- `devops-specs` (`ingadhoc/`) — specs y ADRs del equipo DevOps.

## Stack en una pantalla

- **Compute:** Kubernetes. **Cluster nuevo:** definido en
  `devops-cloud-infra` (Pulumi). **Cluster legacy:** `adhocprod` (en
  migración).
- **Database:** Postgres vía CNPG (operator de CloudNativePG).
- **Bake de imágenes:** `oci-odoo-by-adhoc` para Odoo (CI con
  `odoo_target=<version>`; tags `.next` para test); `devops-ops-tools`
  para el resto.
- **Deploys:** Helm charts (`helm-charts`) — la fuente única para la
  topología del stack desplegado (DB, Odoo, jobs, certs SSL).
- **SaaS provisioning (cruza con Odoo):** el módulo Odoo `saas_k8s`
  extiende `saas_provider` + `saas_database` para ABM de apps Odoo en
  los clusters. Se apoya en `pylib_odoo_saas`. El módulo vive en
  `custom/repositories/` (lado Odoo), no acá.

## Wiki provisoria — dónde está cada cosa

No hay un `devops-wiki` dedicado (todavía). La documentación técnica
del stack vive en el `doc/` de cada repo, con grados de detalle muy
distintos. Mapa rápido:

- **`devops-cloud-infra/doc/`** — el más rico hoy. Arquitectura
  (`architecture.md` + `architecture-diagrams.md`), CI/CD (`cicd.md`),
  networking (`networking-overview.md`, `networks.md`, `psc.md`),
  identity / access (`identity-access-overview.md`, `groups.md`,
  `connect-gateway-authz.md`, `connect-gateway.md`), ingress
  (`ingress-overview.md`, `gateway-api.md`), bastion (`bastion.md`),
  apps en k8s (`k8s_apps.md`), GKE (`gke-overview.md`), config
  (`config.md`). Empezar acá para cualquier pregunta sobre el cluster
  nuevo.
- **`oci-odoo-by-adhoc/doc/`** — bake de imagen Odoo. `layers.md`,
  `dependencies.md`, `others.md`, drawings excalidraw.
- **`pylib_odoo_saas/doc/`** — placeholder mínimo; leer `src/` y
  `test/` directo.
- **`helm-charts/README.MD`** + `charts/<chart>/` — referencia de cada
  chart vive en el README del chart correspondiente.
- **`devops-ops-tools/readme.md`** + `specifications.md` — overview
  de las imágenes no-Odoo.
- **`devops-specs/specs/`** + `decisions/` — specs y ADRs del team.
  `30_done/` decisiones cerradas, `10_draft/` lo que está en arranque.

Cuando una pregunta no encuentre respuesta en `doc/`, leer el código
fuente directo (Pulumi en `__main__.py` + `k8s_apps/` + `infra_cell/`
+ `infra_fleethost/`; charts en `helm-charts/charts/`; Dockerfiles en
`oci-odoo-by-adhoc/<version>/`). **No inventar** — si no está
documentada, decirlo.

## Tuqui Adhoc — connector operativo, no source of truth técnica

Análogo a la regla del workspace OBA (`custom/AGENTS.md`):

- **Sí (connector):** leer tareas / tickets / chatter de DevOps,
  registrar PRs contra una tarea, postear updates en chatter,
  consultar `saas.pull.request` / `adhoc.module`, transcribir videos.
- **No (source of truth técnica):** responder "cómo funciona X en el
  stack" con `odoo_search_read`. La info **no vive en Odoo** — vive en
  los repos clonados acá (`devops-cloud-infra/doc/`, `helm-charts/`,
  Dockerfiles, código Pulumi). Leer ahí antes que llamar al MCP.

`tuqui_context` se corre cuando hay caso explícito (tarea / ticket /
PR), no por reflejo. Cualquier `odoo_create` / `odoo_write` /
`message_post` / `unlink` requiere OK explícito por cada acción.

## Convenciones DevOps

- **Kubeconfigs** viven en `~/.kube/config` (no en este folder, no se
  commitea a ningún repo).
- **Secrets** no entran a este folder; se gestionan vía vault externo /
  sealed-secrets / similar.
- **PR workflow** por repo: `adhoc-cicd/*` opera `branch + PR same-repo`;
  `ingadhoc/*` y `adhoc-dev/*` siguen los 4 casos del adhoc-way (ver
  `~/.adhoc/conventions.md`).
- **Cluster legacy `adhocprod`:** cualquier cambio destructivo va por la
  guild DevOps recurrente (jueves 10am, T-67562).

## Otros contextos relacionados (no acá)

- `custom/adhoc-way-ctx/` — bundle del meta-flujo Adhoc (si tenés team
  `adhoc-way` en `~/.adhoc/teams`).
- `custom/it-ctx/` — herramientas del equipo de sistemas del cliente
  interno (`devops-apt-repository`, `adhocCli`/`r2`, `ansible_notebooks`).
  Spec: `devops-specs/specs/10_draft/internal-team-context.md`.
- `custom/repositories/` — addons Odoo del workspace OBA (incluye
  `saas_k8s`, consumidor del stack DevOps).

---

_Este archivo es regenerado en cada `poststart.sh`. Para editarlo
permanentemente, modificar el heredoc en `.devcontainer/scripts/
poststart.sh` o (mejor) promoverlo a un template versionado en
`devops-specs`._
AGENTS_MD

    # CLAUDE.md y GEMINI.md — punteros cortos a AGENTS.md (ADR 0001 adhoc-way).
    cat > "$devops_ctx/CLAUDE.md" <<'CLAUDE_MD'
# CLAUDE.md

Este folder adopta **[`AGENTS.md`](./AGENTS.md)** como fuente canónica
de instrucciones para agentes de IA (ADR 0001 adhoc-way).

> Antes de responder cualquier mensaje en este folder, leé `AGENTS.md`
> y aplicá sus instrucciones — sobre todo la sección "Cuándo iniciar
> Claude acá vs en `custom/`" y "Tuqui Adhoc — connector operativo".
> Esta carga manual es necesaria porque Claude Code auto-carga solo
> `CLAUDE.md`, no `AGENTS.md`.

Este archivo es regenerado en cada `poststart.sh`. Para editarlo
permanentemente, modificar el heredoc en `.devcontainer/scripts/
poststart.sh`.
CLAUDE_MD

    cat > "$devops_ctx/GEMINI.md" <<'GEMINI_MD'
# GEMINI.md

Este folder adopta **[`AGENTS.md`](./AGENTS.md)** como fuente canónica
de instrucciones para agentes de IA (ADR 0001 adhoc-way).

Antes de responder, leé `AGENTS.md` — sobre todo "Cuándo iniciar
Claude acá vs en `custom/`" y "Tuqui Adhoc — connector operativo".

Este archivo es regenerado en cada `poststart.sh`. Para editarlo
permanentemente, modificar el heredoc en `.devcontainer/scripts/
poststart.sh`.
GEMINI_MD

    # README del folder con instrucciones de regen / opt-out.
    cat > "$devops_ctx/README.md" <<'README_MD'
# devops-ctx

Folder de contexto del team DevOps en el devcontainer OBA. Generado
automáticamente por `.devcontainer/scripts/poststart.sh` cuando
`~/.adhoc/teams` contiene `devops`.

## Cómo regenerar

```bash
refresh-workspace      # re-aplica capa Usuario/Workspace adhoc-way
# o
git fetch              # en cada subrepo individualmente
```

Para regenerar los clones (fresh): `rm -rf custom/devops-ctx/<repo>` y
rebuild.

## Cómo desactivar

Sacar la línea `devops` de `~/.adhoc/teams` (host). En la próxima
rebuild, el folder queda intacto pero no se actualizan los clones.
README_MD

    echo "  custom/devops-ctx/ OK (6 repos default + AGENTS.md + CLAUDE.md + GEMINI.md + README.md)."
}
init_devops_ctx

# Activa adhoc-way-ctx cuando ~/.adhoc/teams contiene `adhoc-way`.
# Spec: ingadhoc/adhoc-way#62 `specs/10_draft/adhoc-way-ctx.md`.
init_adhoc_way_ctx() {
    # Repos default (4) — meta-flujo del ecosistema Adhoc.
    local -a repos=(
        "adhoc-way|git@github.com:ingadhoc/adhoc-way.git"
        "oba-wiki|git@github.com:ingadhoc/oba-wiki.git"
        "skills|git@github.com:ingadhoc/skills.git"
        "adhoc-brand-kit|git@github.com:ingadhoc/adhoc-brand-kit.git"
    )
    ensure_ctx_clones "adhoc-way" "adhoc-way-ctx" "${repos[@]}" || return 0

    local ctx="$HOME/custom/adhoc-way-ctx"

    cat > "$ctx/AGENTS.md" <<'AGENTS_MD'
# adhoc-way context — meta-flujo Adhoc

Activado automáticamente por `poststart.sh` cuando `~/.adhoc/teams`
contiene `adhoc-way`. Spec madre del patrón:
`adhoc-way/specs/10_draft/contextos-opcionales-en-custom.md`. Spec
instance: `adhoc-way/specs/10_draft/adhoc-way-ctx.md`.

## Repos en este folder

- `adhoc-way` (`ingadhoc/`) — meta-repo del Adhoc Dev-Harness.
  Convenciones canónicas, specs, ADRs, scripts (`adhoc-way-install-user.sh`).
  Master de las reglas que aplican cross-repo del ecosistema.
- `oba-wiki` (`ingadhoc/`) — wiki de productos y módulos Odoo by Adhoc.
  Estructura `wiki/<version>/<categoría>/<producto>/<módulo>.md`. Generada
  por el proceso `adhoc-product-wiki` (módulo Odoo); no editar a mano
  para casos no-puntuales — preferir regenerar desde el producto.
- `skills` (`ingadhoc/`) — catálogo cross-vendor de skills CLI (Claude
  Code, Codex, Gemini, Copilot). Catálogo declarativo en `skills.yaml`.
- `adhoc-brand-kit` (`ingadhoc/`) — assets de marca (logos, paletas,
  plantillas). Spec 0013. Pesa ~277 MB; acceso preferente via skill
  `adhoc-brand` (lectura on-demand) más que árbol pleno.

## Convenciones del meta-flujo

- **Specs y ADRs** del propio adhoc-way viven en `adhoc-way/specs/` y
  `adhoc-way/decisions/`. Workflow: `10_draft/` → `20_ready/` →
  `30_done/NNNN-<slug>.md`. Numeración solo al pasar a done.
- **Wiki regenerable:** `oba-wiki/wiki/<v>/` es output del módulo
  `adhoc-product-wiki` en Odoo. Para cambios persistentes, editar el
  producto en Adhoc y regenerar.
- **Skills CLI:** instalar con `npx skills experimental_install` desde
  la raíz del workspace. User-level vs project-level según ADR 0014.
- **Brand kit:** los assets son grandes (277 MB) — agentes IA leen via
  skill `adhoc-brand` salvo que necesiten manipular binarios. Spec 0013.

## Otros contextos relacionados (no acá)

- `custom/oba-specs/` o `custom/ingadhoc-oba-specs/` — specs de
  productos OBA. **Queda top-level** porque la usa todo dev OBA, no solo
  los del meta-flujo.
- `custom/devops-ctx/` — bundle DevOps (si el dev tiene team `devops`).
  Spec madre en `devops-specs`.
- `custom/tuqui-ctx/` — bundle Tuqui / AI (si el dev tiene team `tuqui`,
  pendiente implementación + validación team Tuqui).
- `src/adhoc-way-ctx/` — fallback baked (`adhoc-way` + `oba-wiki`) para
  devs sin team `adhoc-way` activo — read-only via el router de PR #41.

---

_Este archivo es regenerado en cada `poststart.sh`. Para editarlo
permanentemente, modificar el heredoc en `.devcontainer/scripts/
poststart.sh`._
AGENTS_MD

    # CLAUDE.md y GEMINI.md — punteros cortos a AGENTS.md (ADR 0001 adhoc-way).
    cat > "$ctx/CLAUDE.md" <<'CLAUDE_MD'
# CLAUDE.md

Este folder adopta **[`AGENTS.md`](./AGENTS.md)** como fuente canónica
de instrucciones para agentes de IA (ADR 0001 adhoc-way).

> Antes de responder cualquier mensaje en este folder, leé `AGENTS.md`
> y aplicá sus instrucciones. Esta carga manual es necesaria porque
> Claude Code auto-carga solo `CLAUDE.md`, no `AGENTS.md`.

Este archivo es regenerado en cada `poststart.sh`. Para editarlo
permanentemente, modificar el heredoc en `.devcontainer/scripts/
poststart.sh`.
CLAUDE_MD

    cat > "$ctx/GEMINI.md" <<'GEMINI_MD'
# GEMINI.md

Este folder adopta **[`AGENTS.md`](./AGENTS.md)** como fuente canónica
de instrucciones para agentes de IA (ADR 0001 adhoc-way).

Antes de responder, leé `AGENTS.md` y aplicá sus instrucciones.

Este archivo es regenerado en cada `poststart.sh`. Para editarlo
permanentemente, modificar el heredoc en `.devcontainer/scripts/
poststart.sh`.
GEMINI_MD

    cat > "$ctx/README.md" <<'README_MD'
# adhoc-way-ctx

Folder de contexto del meta-flujo Adhoc en el devcontainer OBA. Generado
automáticamente por `.devcontainer/scripts/poststart.sh` cuando
`~/.adhoc/teams` contiene `adhoc-way`.

## Cómo regenerar

```bash
refresh-workspace      # re-aplica capa Usuario/Workspace adhoc-way
# o
git fetch              # en cada subrepo individualmente
```

Para regenerar los clones (fresh): `rm -rf custom/adhoc-way-ctx/<repo>`
y rebuild.

## Cómo desactivar

Sacar la línea `adhoc-way` de `~/.adhoc/teams` (host). En la próxima
rebuild, el folder queda intacto pero no se actualizan los clones.

Devs sin team `adhoc-way` activo siguen viendo `adhoc-way` y `oba-wiki`
baked en `/home/odoo/src/adhoc-way-ctx/` (read-only fallback).
README_MD

    echo "  custom/adhoc-way-ctx/ OK (4 repos default + AGENTS.md + CLAUDE.md + GEMINI.md + README.md)."
}
init_adhoc_way_ctx

# Activa tuqui-ctx cuando ~/.adhoc/teams contiene `tuqui`.
# Pendiente: validación cruzada con team Tuqui para confirmar set
# definitivo de repos, orgs/URLs (algunas viven en Tuqui-AI/ org) y wiki
# seed. Spec: `adhoc-way/specs/10_draft/tuqui-ctx.md` (ingadhoc/adhoc-way#62).
# init_tuqui_ctx() — placeholder, no implementado todavía.

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
