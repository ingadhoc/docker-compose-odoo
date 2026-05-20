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

    # Proyectos del ecosistema en custom/ — detección por presencia de
    # AGENTS.md en el dir top-level. Cualquier `custom/<project>/AGENTS.md`
    # marca al proyecto como "activo" (mounteado desde host vía docker-compose.
    # override.yml — ver decisión §6 #11-#15 del spec OBA bake). El listing
    # también incluye repos directos del dev que tengan AGENTS.md propio.
    #
    # Sin compat hacia atrás con `custom/<project>-ctx/` (decisión §6 #14):
    # los contextos viejos no se detectan más por sufijo. Si un dev tenía
    # un layout legacy con clones internos, lo migra a mounts post-rebuild.
    declare -A custom_others
    declare -A projects
    for d in "$CUSTOM"/*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        [[ $name == .* || $name == repositories || $name == src || $name == adhoc || $name == tmp* ]] && continue
        if [[ -f "$d/AGENTS.md" ]]; then
            projects[$name]="${d%/}"
        else
            custom_others[$name]=1
        fi
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

## Modos de trabajo (proyectos del ecosistema mounteados)

Al pararte acá con un agente IA, elegí el modo según el tema. Los proyectos del ecosistema declarados como opt-in en `docker-compose.override.yml` aparecen como `custom/<proyecto>/` con su `AGENTS.md` propio (que viene committeado en el repo upstream). El agente carga el `AGENTS.md` del proyecto correspondiente cuando se para adentro.

INTRO
        if [[ ${#projects[@]} -eq 0 ]]; then
            echo "_Sin proyectos del ecosistema mounteados todavía. Ver \`docker-compose.override.yml.example\` para activar mounts opt-in (devops, adhoc-way, tuqui)._"
        else
            for name in $(echo "${!projects[@]}" | tr ' ' '\n' | sort); do
                path="${projects[$name]}"
                echo "- **$name**: \`$path/\` — ver \`$path/AGENTS.md\`."
            done
        fi
        cat <<'STRUCT'

**Default** (sin contexto explícito): módulos OBA, tareas Tuqui, debugging Odoo. Seguir lo que sigue en este AGENTS.md.

## Estructura

- **`repositories/`:** repos del dev con módulos Odoo (editables, branch activa).
- **Proyectos del ecosistema mounteados:** ver sección "Modos de trabajo" arriba (`custom/<proyecto>/` con `AGENTS.md` propio, declarado en `docker-compose.override.yml`).
- **Otros repos en `custom/`:** clones directos del dev sin `AGENTS.md` (overrides de baked como `odoo`/`enterprise`, repos puntuales). Listado efectivo abajo.
- **`src/`:** repos baked de la imagen no presentes en `custom/` (referencia, symlinks de container).
  - `src/repositories/`: repos baked no en `repositories/`.

## Otros repos en custom/ (sin AGENTS.md, fuera de repositories/ y src/)

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
    # Uso: install_cli_if_missing <cmd> <pkg> [--upgrade]
    #
    # Por default: solo instala si el binario falta (`command -v` falla). Si
    # ya está (típicamente porque el bake OCI lo trajo), no toca nada.
    #
    # `--upgrade`: corre `npm install -g` siempre, esté o no el binario.
    # Esto deja que npm decida — para git URLs sin ref consulta el SHA del
    # default branch y reusa cache si coincide (cache hit ~1-2s), o
    # re-instala si hay commits nuevos. Útil para paquetes que iteran
    # rápido y donde el dev no rebuildea la imagen seguido.
    local cmd="$1" pkg="$2" mode="${3:-skip-if-present}"
    if [ "$mode" = "--upgrade" ]; then
        echo "Instalando/actualizando $cmd ($pkg)..."
        npm install -g "$pkg" --quiet \
            && echo "$cmd OK ($(command -v "$cmd"), $($cmd --version 2>/dev/null || echo '?'))." \
            || echo "FALLO: no se pudo instalar/actualizar $pkg"
    elif ! command -v "$cmd" &>/dev/null; then
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
# adhoc-way — CLI del patrón cross-vendor (ingadhoc/adhoc-way).
# `--upgrade` porque itera rápido y los devs no rebuildean la imagen OCI
# todos los días; queremos que cada arranque del devcontainer agarre el
# último commit del default branch. Usamos `git+https://` (no `github:`
# shorthand) por la misma razón que el bake OCI (#33): respeta la auth
# via insteadOf con el GITHUB_BOT_TOKEN / credential helper del host;
# el shorthand resuelve a codeload.github.com y queda sin auth en repos
# privados.
install_cli_if_missing adhoc-way git+https://github.com/ingadhoc/adhoc-way.git --upgrade

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

# ingadhoc/skills — catálogo interno (solo skills de dominio Odoo +
# product-sdd). Las skills universales del ecosistema
# (adhoc-way-bootstrap, adhoc-way-pr-flow, adhoc-way-contribute) migraron
# al repo `ingadhoc/adhoc-way/skills/` con prefijo `adhoc-way-`
# (versions.json#canonical_skills_meta de adhoc-way es fuente de verdad
# post-migración). Se instalan via bake user-level en la imagen OCI dev
# (PR adhoc-cicd/oci-odoo-by-adhoc#33). En containers que no tengan ese
# bake disponible todavía, los agentes pueden seguir usando el binario
# `adhoc-way` para iniciar la capa Usuario manualmente.
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

# Convenciones Adhoc adentro del container — capa Usuario.
#
# El binario `adhoc-way` se instala arriba via `install_cli_if_missing
# adhoc-way ... --upgrade`. Dos fuentes posibles:
#
#   - Bake OCI (adhoc-cicd/oci-odoo-by-adhoc#33): el binario viene
#     pre-instalado en /usr/local/bin/. El install_cli_if_missing de
#     arriba, con `--upgrade`, lo refresca al HEAD del default branch si
#     hay commits nuevos (cache hit ~1-2s cuando no hay updates).
#   - Sin bake (imagen vieja, dev recién agregado a la imagen, etc.):
#     install_cli_if_missing lo instala en este postStart.
#
# En ambos casos, el binario queda disponible para que un agente IA con
# `tuqui_context` cargado dispare `adhoc-way init --user-json '{...}'`
# y materialice la capa Usuario (~/.adhoc/conventions.md, user.json,
# state.json + hooks user-level en .claude/.codex/.gemini/.copilot).
# El postStart NO ejecuta `init` — el init requiere datos del dev
# concreto que solo el agente conoce vía tuqui_context (decisión §6 #8
# del spec OBA bake en ingadhoc/adhoc-way#99).
if command -v adhoc-way >/dev/null 2>&1; then
    echo "Binario adhoc-way disponible: $(command -v adhoc-way) ($(adhoc-way --version 2>/dev/null || echo 'version desconocida'))"
    echo "  La capa Usuario la dispara un agente IA con tuqui_context cargado via 'adhoc-way init --user-json ...'"
else
    echo "AVISO: binario adhoc-way no quedó instalado (revisar log de install_cli_if_missing arriba)."
fi

# Wrapper refresh-workspace — re-aplica la capa Usuario sin rebuild del
# devcontainer. Re-lee el user.json materializado por el init previo (lo
# generó el agente IA con tuqui_context). Útil cuando se actualizó la
# versión de conventions del paquete adhoc-way y el dev quiere bajar el
# bloque managed sin esperar la próxima sesión.
REFRESH_BIN="$HOME/.local/bin/refresh-workspace"
mkdir -p "$(dirname "$REFRESH_BIN")"
cat > "$REFRESH_BIN" <<'REFRESH_EOF'
#!/bin/bash
set -e
USER_JSON="$HOME/.adhoc/user.json"
if [ ! -f "$USER_JSON" ]; then
    echo "ERROR: $USER_JSON no existe — corré primero 'adhoc-way init --user-json ...' desde un agente IA con tuqui_context cargado." >&2
    exit 1
fi
if ! command -v adhoc-way >/dev/null 2>&1; then
    echo "ERROR: binario adhoc-way no encontrado en PATH. El postStart lo instala via 'install_cli_if_missing adhoc-way ... --upgrade'; revisá el log del postStart o instalalo a mano con 'npm install -g git+https://github.com/ingadhoc/adhoc-way.git'." >&2
    exit 1
fi
exec adhoc-way init --user-json "$(cat "$USER_JSON")" "$@"
REFRESH_EOF
chmod +x "$REFRESH_BIN"
echo "refresh-workspace disponible en $REFRESH_BIN"

# Detección de proyectos del ecosistema mounteados (modelo opt-in via
# docker-compose.override.yml, decisión §6 #11-#15 del spec OBA bake en
# ingadhoc/adhoc-way#99). Reemplaza el patrón viejo
# `init_<scope>_ctx + ensure_ctx_clones` que clonaba repos adentro de
# `custom/<project>-ctx/` durante el poststart.
#
# Cada dev declara mounts opt-in en `docker-compose.override.yml` (ver
# template en `docker-compose.override.yml.example`). Convención de paths
# host por defecto (decisión §6 #12):
#
#   ${HOME}/repositorios/devops/    → /home/odoo/custom/devops
#   ${HOME}/repositorios/adhoc-way/ → /home/odoo/custom/adhoc-way
#   ${HOME}/tuqui/                  → /home/odoo/custom/tuqui  (opt-in extra)
#
# Sin compat hacia atrás con paths legacy `custom/<project>-ctx/` (decisión
# §6 #14): JJS y AZ adaptan sus setups locales post-merge.
#
# Helper genérico: itera `custom/<project>/` con `AGENTS.md` y registra
# qué proyectos están activos. El AGENTS.md consolidado del workspace lo
# regenera `build_workspace` aparte.
#
# Decisión sobre hooks opt-in:
#   Se evaluó ejecutar automáticamente `<project>/scripts/devcontainer-
#   postcontainer.sh` por cada proyecto detectado, pero eso permitiría
#   ejecución implícita de código desde cualquier repo mounteado en
#   `custom/` con un AGENTS.md. Aun cuando los mounts vienen del host
#   del dev (su threat model propio), preferimos opt-in explícito antes
#   de habilitar auto-ejecución. Si emerge necesidad concreta, sumar
#   declaración explícita por proyecto en docker-compose.override.yml o
#   en una whitelist ~/.adhoc/.
for_each_mounted_project() {
    local count=0
    local d name
    for d in "$HOME/custom"/*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        [[ $name == .* || $name == repositories || $name == src || $name == adhoc || $name == tmp* ]] && continue
        [[ -f "$d/AGENTS.md" ]] || continue
        echo "  Proyecto mounteado: $name ($d)"
        count=$((count + 1))
    done
    echo "for_each_mounted_project: $count proyecto(s) detectado(s)."
}
for_each_mounted_project


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
