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
    declare -A stale_mounts
    for d in "$CUSTOM"/*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        [[ $name == .* || $name == repositories || $name == src || $name == adhoc || $name == tmp* ]] && continue
        if [[ -f "$d/AGENTS.md" ]]; then
            projects[$name]="${d%/}"
        elif [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then
            # Dir vacío directo bajo custom/ = casi seguro un mountpoint viejo que
            # quedó tras sacar o renombrar un bind (p.ej. custom/oba-project tras
            # el rename del proyecto a oba). No es un repo: lo dejamos fuera del
            # listado de "otros repos". El AVISO accionable (con `sudo rmdir`) lo
            # da discover-mounts.sh en el HOST (initializeCommand, siempre visible
            # en el log del rebuild — el postStart lo colapsa VS Code).
            stale_mounts[$name]=1
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

    # workspace-map.md — las tres listas dinámicas del workspace (proyectos
    # montados, otros repos en custom/, repos del dev), generadas en cada
    # rebuild. La parte fija del AGENTS.md ya no se genera acá: vive
    # versionada en oba-project (workspace/custom-AGENTS.md) y se symlinkea
    # más abajo — mismo patrón que review/odoo-adhoc.md.
    {
        cat <<'MAPHEAD'
# Workspace map

_Generado por el postStart en cada rebuild — no editar. La parte fija del workspace está en [`AGENTS.md`](./AGENTS.md)._

## Proyectos del ecosistema montados

MAPHEAD
        if [[ ${#projects[@]} -eq 0 ]]; then
            echo "_Sin proyectos del ecosistema detectados en el host. \`discover-mounts.sh\` busca por default \`~/repositorios/{devops,adhoc-way,oba,...}\` — cloná alguno y rebuild, o agregá un mount custom en \`docker-compose.override.yml\`._"
        else
            for name in $(echo "${!projects[@]}" | tr ' ' '\n' | sort); do
                path="${projects[$name]}"
                echo "- **$name**: \`$path/\` — ver \`$path/AGENTS.md\`."
            done
        fi
        cat <<'MAPOTHERS'

## Otros repos en custom/ (sin AGENTS.md, fuera de repositories/ y src/)

MAPOTHERS
        if [[ ${#custom_others[@]} -eq 0 ]]; then
            echo "_Ninguno todavía._"
        else
            for name in $(echo "${!custom_others[@]}" | tr ' ' '\n' | sort); do
                echo "- \`$name\`"
            done
        fi
        cat <<'MAPREPOS'

## Repos del dev en repositories/

MAPREPOS
        if [[ ${#in_custom[@]} -eq 0 ]]; then
            echo "_Ningún repo de módulos clonado todavía._"
        else
            for name in $(echo "${!in_custom[@]}" | tr ' ' '\n' | sort); do
                echo "- \`$name\`"
            done
        fi
    } > "$CUSTOM/workspace-map.md"

    # AGENTS.md — symlink a la parte fija versionada en oba-project.
    # rm previo: si quedó un symlink colgado (oba desmontado), el cat del
    # fallback escribiría a través de él; el rm deja ambos casos uniformes.
    local oba_custom_agents="$CUSTOM/oba/workspace/custom-AGENTS.md"
    rm -f "$CUSTOM/AGENTS.md"
    if [[ -f "$oba_custom_agents" ]]; then
        ln -s "$oba_custom_agents" "$CUSTOM/AGENTS.md"
        echo "AGENTS.md → $oba_custom_agents"
    else
        # Tres motivos distintos para el stub, con tres fixes distintos. El
        # estado de oba sale de los mapas que ya armó el loop de arriba: un
        # `-d custom/oba` a secas da true también para un mountpoint vacío
        # (bind sacado o renombrado en el host), y ahí mandaríamos al dev a
        # hacer `git pull` sobre un path que no existe.
        local stub_por
        if [[ -n "${projects[oba]:-}" ]]; then
            stub_por="el clone montado en \`custom/oba\` todavía no tiene ese archivo:
actualizalo (\`git pull\` en \`~/repositorios/oba\`) y rebuildeá."
            echo "AVISO: oba montado pero sin workspace/custom-AGENTS.md (clone viejo) — AGENTS.md stub generado."
        elif [[ -n "${stale_mounts[oba]:-}" ]]; then
            stub_por="\`custom/oba\` es un mountpoint vacío: el clone del host
desapareció o cambió de nombre. Verificá \`~/repositorios/oba\` y rebuildeá."
            echo "AVISO: custom/oba vacío (mount stale) — AGENTS.md stub generado."
        else
            stub_por="el proyecto \`oba\` no está montado: clonalo en
\`~/repositorios/oba\` y rebuildeá (\`discover-mounts.sh\` lo detecta solo)."
            echo "oba no montado — AGENTS.md stub generado."
        fi
        # Stub mínimo: apunta a la fuente en vez de duplicar su contenido.
        cat > "$CUSTOM/AGENTS.md" <<STUB
# Workspace OBA

La parte fija de este AGENTS.md vive versionada en \`ingadhoc/oba-project\`
(\`workspace/custom-AGENTS.md\`) y acá falta porque $stub_por

Los listados del workspace (proyectos del ecosistema montados, otros repos
en \`custom/\`, repos del dev) están en [\`workspace-map.md\`](./workspace-map.md).
STUB
    fi

    # El digest de oba es un componente clonado adentro (oba/digest/). Sin él,
    # la wiki de módulos desaparece en silencio — avisar loud. Va afuera del if
    # de arriba: es ortogonal al AGENTS.md, y un clone viejo sin digest también
    # tiene que verlo.
    if [[ -n "${projects[oba]:-}" ]] && [[ ! -f "$CUSTOM/oba/digest/README.md" ]]; then
        echo "AVISO: oba montado SIN digest/ (la wiki de módulos). Es un componente:"
        echo "       en el host, cloná ingadhoc/oba-project-memory en ~/repositorios/oba/digest"
    fi

    # Imperativo, no un puntero pasivo: es el único archivo del workspace que
    # el agente carga solo (los AGENTS.md de los proyectos montados son
    # carpetas hermanas y no se inyectan), así que si acá solo dice "ver
    # AGENTS.md" el ruteo por tema no llega a ocurrir.
    #
    # Pide UN archivo, no dos: el AGENTS.md es lectura irreducible (son las
    # instrucciones del workspace) y adentro está el ruteo, que decide si hace
    # falta el mapa. Exigir workspace-map.md acá le cobraba esa lectura al caso
    # default, que es justo el que el ruteo declara exento — detectado por el
    # eval OBA-E12 de oba-project.
    cat > "$CUSTOM/CLAUDE.md" <<'EOF'
# CLAUDE.md
**Antes de responder el primer mensaje de esta sesión, leé
[`AGENTS.md`](./AGENTS.md) con la tool Read** — es la fuente canónica de
instrucciones de este workspace, y trae el ruteo por tema: cuándo el pedido se
contesta acá mismo y cuándo hay que ir a leer el `AGENTS.md` de otro proyecto
montado. No adelantes otras lecturas: el ruteo dice qué hace falta según el
pedido.
EOF
    cat > "$CUSTOM/GEMINI.md" <<'EOF'
# GEMINI.md
**Antes de responder el primer mensaje de esta sesión, leé
[`AGENTS.md`](./AGENTS.md)** — es la fuente canónica de instrucciones de este
workspace, y trae el ruteo por tema: cuándo el pedido se contesta acá mismo y
cuándo hay que ir a leer el `AGENTS.md` de otro proyecto montado. No adelantes
otras lecturas: el ruteo dice qué hace falta según el pedido.
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

# Sandbox de codex — shim al backend Landlock cuando bubblewrap no puede.
#
# Desde 0.147 codex sandboxea con bubblewrap (lo vendorea en su paquete npm) en
# TODOS los modos, incluido read-only. bwrap necesita crear un user namespace y
# el perfil seccomp default de Docker lo bloquea: adentro del container codex no
# ejecuta ni un comando, o sea que tampoco lee archivos. Landlock no necesita
# namespaces y sigue enforceando read-only, así que el shim fuerza ese backend.
#
# Se autodesactiva: probamos el bwrap vendoreado y si funciona borramos el shim.
# Limitación conocida — Landlock solo soporta `-s read-only`; con
# `-s workspace-write` codex panickea (feature deprecada aguas arriba).
#
# El flag tiene fecha: 0.149.1 ya avisa en runtime que `use_legacy_landlock` se
# elimina pronto. Cuando pase, el `-c` queda como clave desconocida y codex
# vuelve a bubblewrap — o sea al estado roto de hoy, no a algo peor, y el probe
# de arriba no lo detecta porque mira bwrap y no el flag. El fix durable es otro:
# que el container gane el permiso de seccomp (descartado: hacen falta también
# apparmor y SYS_ADMIN, casi privilegiado), que codex arregle su backend, o correr
# codex en un container hermano sin credenciales montadas.
CODEX_SHIM="$HOME/.local/bin/codex"
CODEX_SHIM_MARK="# adhoc: codex landlock shim"

codex_real_bin() {
    local c
    for c in "$HOME/.local/bin/codex" /usr/local/bin/codex /usr/bin/codex; do
        [ -x "$c" ] || continue
        grep -q "$CODEX_SHIM_MARK" "$c" 2>/dev/null && continue
        echo "$c"
        return 0
    done
    return 1
}

drop_codex_shim() {
    if [ -f "$CODEX_SHIM" ] && grep -q "$CODEX_SHIM_MARK" "$CODEX_SHIM"; then
        rm -f "$CODEX_SHIM"
        echo "codex: sandbox nativo OK, shim de Landlock removido."
    fi
}

ensure_codex_landlock_shim() {
    local real pkg bw
    real="$(codex_real_bin)" || return 0
    if [ "$real" = "$CODEX_SHIM" ]; then
        echo "codex: instalado en $CODEX_SHIM, no puedo shimearlo ahí." \
             "Si el sandbox falla: codex -c features.use_legacy_landlock=true"
        return 0
    fi
    pkg="$(readlink -f "$real")"
    pkg="${pkg%/bin/*}"
    bw="$(find "$pkg" -type f -name bwrap -perm -u+x 2>/dev/null | head -1)"
    if [ -z "$bw" ] || "$bw" --dev-bind / / --proc /proc true 2>/dev/null; then
        drop_codex_shim
        return 0
    fi
    mkdir -p "$(dirname "$CODEX_SHIM")"
    cat > "$CODEX_SHIM" <<SHIM
#!/bin/bash
$CODEX_SHIM_MARK — bwrap no puede crear user namespaces en el devcontainer.
# Lo instala el poststart; para saltearlo, invocar $real directo.
exec "$real" -c features.use_legacy_landlock=true "\$@"
SHIM
    chmod +x "$CODEX_SHIM"
    echo "codex: bwrap no puede crear namespaces, shim de Landlock instalado en $CODEX_SHIM."
}
ensure_codex_landlock_shim
# Auth de git hacia GitHub — fallback a HTTPS cuando no hay clave SSH.
#
# VS Code copia el `~/.gitconfig` del host al crear el container (no lo
# montea), y en el host la clave SSH existe, así que nada declara el
# fallback a HTTPS acá adentro. Si el agente forwardeado no tiene clave
# utilizable para GitHub, todo remote `git@github.com:` falla: el
# `git ls-remote` de install_adhoc_way cae al fallback de reinstalar
# (WARN visible en el log del postCreate), y al dev le fallan fetch y
# pull en cada repo con remote SSH.
#
# Estrictamente aditivo, en dos condiciones:
#   1. Si SSH autentica contra GitHub, no se toca nada.
#   2. Si el dev ya declaró un insteadOf propio, se respeta.
# O sea: solo escribe donde hoy está roto. La reescritura reusa el
# credential helper que VS Code ya inyecta, y queda acotada a github.com.
ensure_github_https_fallback() {
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
           -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        echo "git: SSH a GitHub autentica; dejo los remotes como están."
        return 0
    fi
    if [ -n "$(git config --global --get-all url."https://github.com/".insteadOf 2>/dev/null)" ]; then
        echo "git: insteadOf hacia GitHub ya declarado; no lo piso."
        return 0
    fi
    git config --global url."https://github.com/".insteadOf "git@github.com:"
    echo "git: SSH a GitHub no autentica; remotes git@github.com: reescritos a HTTPS."
}
ensure_github_https_fallback

# adhoc-way — CLI del patrón cross-vendor (ingadhoc/adhoc-way).
#
# Reinstalación condicional: comparamos el SHA del HEAD remoto contra
# el SHA cacheado tras el último install local. Solo corremos
# `npm install -g` si difieren o falta cualquiera de los dos. Esto
# evita el `npm install -g git+https://...` en cada arranque
# (medido ~6-11s incluso cuando no hay cambios) — el `git ls-remote`
# que reemplaza el check tarda ~2s.
#
# `git ls-remote` se eligió sobre la GitHub Contents API porque hereda
# la auth de git tal cual está configurada en el devcontainer: SSH key
# forwarded desde el host (caso típico en los devcontainers Adhoc).
# No requiere extraer tokens a mano.
#
# URL SSH para el check liviano (mismo patrón que el clone de skills
# más abajo). `git+https://` para el `npm install` porque npm necesita
# el prefijo `git+` y respeta `insteadOf` con GITHUB_BOT_TOKEN cuando
# está disponible (consistente con bake OCI #33).
#
# `GIT_TERMINAL_PROMPT=0` como red de seguridad: si la auth git falla
# por cualquier motivo, queremos que `git ls-remote` salga con error
# en silencio y caiga al fallback (reinstalar) — NO que abra
# `/dev/tty` para preguntar usuario y cuelgue el postCreate.
install_adhoc_way() {
    local pkg="git+https://github.com/ingadhoc/adhoc-way.git"
    local repo_url="git@github.com:ingadhoc/adhoc-way.git"
    local sha_file="$HOME/.cache/adhoc-way/installed.sha"
    local installed_sha="" remote_sha=""

    if command -v adhoc-way >/dev/null 2>&1; then
        installed_sha=$(cat "$sha_file" 2>/dev/null || true)
    fi

    remote_sha=$(GIT_TERMINAL_PROMPT=0 git ls-remote "$repo_url" HEAD 2>/dev/null | awk '{print $1; exit}' || true)

    if [ -n "$installed_sha" ] && [ -n "$remote_sha" ] && [ "$installed_sha" = "$remote_sha" ]; then
        echo "adhoc-way al día (sha ${remote_sha:0:7})."
        return 0
    fi

    if [ -z "$remote_sha" ]; then
        echo "WARN: no pude consultar SHA remoto de adhoc-way; reinstalo por las dudas."
    elif [ -z "$installed_sha" ]; then
        echo "Instalando adhoc-way (sin cache local; remoto ${remote_sha:0:7})..."
    else
        echo "Actualizando adhoc-way (${installed_sha:0:7} → ${remote_sha:0:7})..."
    fi

    if npm install -g "$pkg" --quiet; then
        echo "adhoc-way OK ($(command -v adhoc-way), $(adhoc-way --version 2>/dev/null || echo '?'))."
        if [ -n "$remote_sha" ]; then
            mkdir -p "$(dirname "$sha_file")"
            echo "$remote_sha" > "$sha_file"
        fi
    else
        echo "FALLO: no se pudo instalar/actualizar adhoc-way"
    fi
}
install_adhoc_way

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

if command -v gh &>/dev/null; then
    gh auth status &>/dev/null 2>&1 && echo "gh: autenticado OK." || echo "gh: no autenticado."
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
    # odoo-upgrade-lines se mudó al workspace Tuqui (skill MCP, multi-plataforma):
    # cargar con skill_detail(name='odoo-upgrade-lines') — ingadhoc/skills#90
    # Cadena de migración actua-20 (task 72749) — viven en odoo/modules/upgrades/
    # del catálogo; la instalación resuelve por nombre, así que los moves de
    # carpeta no rompen. odoo-code-migration-batch necesita más de una versión a
    # la vez (su flujo completo corre en el host), pero se instala igual por
    # paridad de catálogo.
    "odoo-module-code-migration"
    "odoo-code-migration-batch"
    "odoo-upgrade-declarative-checks"
    "odoo-test-from-commit"
    "odoo-test-from-video"
    "odoo-module-generator"
    "odoo-auto-readme"          # antes: odoo-readme (rota silenciosa)
    "odoo-commit-explainer"     # mensajes de commit Odoo-style
    "odoo-video-to-docs"        # docs desde video — alto uso real (Academy)
    # SDD / specs
    "product-sdd"
    # General
    "gcp-logs"
)

# find-skills (descubrimiento) y skill-creator (autoría) ya NO se auto-instalan
# acá: son tier "recommended" (pull, no push) de adhoc-way (ADR 0032). No son
# esenciales; `adhoc-way init` (que corre más abajo en este poststart) las
# surfacea con su comando de install y el dev las instala si quiere. Antes se
# instalaban por `npx skills`, el camino que el tier recommended reemplaza.

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

    # (find-skills / skill-creator ya no se instalan acá — son tier recommended
    # de adhoc-way; las surfacea `adhoc-way init`. Ver nota más arriba, donde
    # estaba la lista de skills externas.)

    if [ "$install_failed" -eq 0 ] && [ -d "$PWD/$SKILL_PATH" ]; then
        echo "Skills installed."
    else
        echo "FALLO: no se pudieron instalar las skills. Mostrando últimas líneas del log de instalación:"
        tail -n 200 "$LOG_FILE" || true
    fi

    rm "$LOG_FILE" || true
fi

# Bootstrap mínimo de la capa Usuario adhoc-way.
#
# Post-PR ingadhoc/adhoc-way#134 (init progresivo, v0.4.0), `adhoc-way init`
# corre en dos stages:
#   - Stage 0 (siempre, no requiere user.json) escribe directiva user-level
#     + SessionStart hook en cada vendor detectado, sincroniza state.json.
#   - Stage 1 (read-only sobre user.json) reporta estado de identidad.
#     Si user.json no existe o está malformado, no falla — solo loguea
#     "identidad pendiente"; el primer "hola" al agente IA gatilla el menú
#     onboarding y la completa via tuqui-adhoc.
#
# Por eso el bootstrap acá se reduce a invocar el binario. Versiones previas
# creaban un user.json parcial desde git config — ya no hace falta y de
# hecho era contraproducente (el agente podía interpretarlo como "identidad
# completa" y saltearse el onboarding).
bootstrap_adhoc_way_user() {
    if ! command -v adhoc-way >/dev/null 2>&1; then
        echo "AVISO: binario adhoc-way no instalado — skip bootstrap capa Usuario."
        return 0
    fi
    echo "Binario adhoc-way disponible: $(command -v adhoc-way) ($(adhoc-way --version 2>/dev/null || echo 'version desconocida'))"

    echo "Bootstrap: corriendo 'adhoc-way init'..."
    if ! adhoc-way init; then
        echo "WARN: adhoc-way init falló — la capa Usuario puede quedar incompleta."
    fi
}
bootstrap_adhoc_way_user

# Wrapper refresh-workspace — re-aplica la capa Usuario sin rebuild del
# devcontainer. Útil cuando se actualizó la versión de conventions del
# paquete adhoc-way y el dev quiere bajar el bloque managed sin esperar
# la próxima sesión. En v0.4 `init` es progresivo (Stage 0 no requiere
# user.json), así que el wrapper es trivial.
REFRESH_BIN="$HOME/.local/bin/refresh-workspace"
mkdir -p "$(dirname "$REFRESH_BIN")"
cat > "$REFRESH_BIN" <<'REFRESH_EOF'
#!/bin/bash
set -e
if ! command -v adhoc-way >/dev/null 2>&1; then
    echo "ERROR: binario adhoc-way no encontrado en PATH. El postStart lo instala via install_adhoc_way; revisá el log del postStart o instalalo a mano con 'npm install -g git+https://github.com/ingadhoc/adhoc-way.git'." >&2
    exit 1
fi
exec adhoc-way init "$@"
REFRESH_EOF
chmod +x "$REFRESH_BIN"
echo "refresh-workspace disponible en $REFRESH_BIN"

# Detección de proyectos del ecosistema mounteados (decisión §6 #11-#15
# del spec OBA bake en ingadhoc/adhoc-way#99). Reemplaza el patrón viejo
# `init_<scope>_ctx + ensure_ctx_clones` que clonaba repos adentro de
# `custom/<project>-ctx/` durante el poststart.
#
# Los mounts se generan auto en el HOST pre-rebuild via
# `discover-mounts.sh` (initializeCommand de devcontainer.json), que
# detecta presencia de paths del ecosistema y los emite a
# `docker-compose.auto-mounts.yml`. Convención de paths host por defecto
# (catálogo hardcodeado en discover-mounts.sh — config de este devcontainer):
#
#   ${HOME}/repositorios/devops/              → /home/odoo/custom/devops
#   ${HOME}/repositorios/adhoc-way/           → /home/odoo/custom/adhoc-way
#   ${HOME}/repositorios/oba/                 → /home/odoo/custom/oba
#   ${HOME}/repositorios/odumbo/              → /home/odoo/custom/odumbo
#   ${HOME}/repositorios/consultoria-tecnica/ → /home/odoo/custom/consultoria-tecnica
#
# Para paths no-default o repos fuera del catálogo, el dev declara mounts
# manuales en `docker-compose.override.yml` (opt-in, gitignored).
#
# Sin compat hacia atrás con paths legacy `custom/<project>-ctx/` (decisión
# §6 #14): JJS y AZ adaptan sus setups locales post-merge.
#
# Este helper corre adentro del container, post-mount: itera
# `custom/<project>/` con `AGENTS.md` y registra qué proyectos están
# activos. Las listas dinámicas del workspace las regenera `build_workspace`
# aparte, en custom/workspace-map.md (el AGENTS.md es symlink a oba-project).
#
# Decisión sobre hooks opt-in:
#   Se evaluó ejecutar automáticamente `<project>/scripts/devcontainer-
#   postcontainer.sh` por cada proyecto detectado, pero eso permitiría
#   ejecución implícita de código desde cualquier repo mounteado en
#   `custom/` con un AGENTS.md. Aun cuando los mounts vienen del host
#   del dev (su threat model propio), preferimos opt-in explícito antes
#   de habilitar auto-ejecución. Si emerge necesidad concreta, sumar
#   declaración explícita por proyecto en discover-mounts.sh o en una
#   whitelist ~/.adhoc/.
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

# Reglas Claude Code desde proyecto oba mounteado.
#
# COPIA, no symlink: el cargador de `.claude/rules/` recorre el directorio por
# su cuenta y NO resuelve las entradas que son symlink — las saltea sin error.
# Verificado con una regla de prueba idéntica en las dos formas (misma carpeta,
# mismo cwd, Claude Code 2.1.258): como archivo real entra en contexto, como
# symlink no, sea el target absoluto o relativo. `custom/AGENTS.md` sigue siendo
# symlink porque a ese lo abre el agente con un Read normal, que sí lo resuelve.
#
# El dir se regenera en cada postCreate (ver el `rm -rf $HOME/custom/.claude`
# del bloque de limpieza), así que la copia no se pudre entre rebuilds.
#
# Recorre toda la carpeta en vez de nombrar un archivo: `oba/review/` es la
# fuente única declarada de estas reglas, y una regla nueva no debería requerir
# un PR acá. README.md queda afuera a propósito — documenta la carpeta, no es
# una regla, y al no tener frontmatter `paths:` entraría en TODAS las sesiones.
OBA_REVIEW_DIR="$HOME/custom/oba/review"
CLAUDE_RULES_DIR="$HOME/custom/.claude/rules"
if [[ -d "$OBA_REVIEW_DIR" ]]; then
    mkdir -p "$CLAUDE_RULES_DIR"
    rules_copiadas=0
    for rule in "$OBA_REVIEW_DIR"/*.md; do
        [[ -f "$rule" ]] || continue
        [[ "$(basename "$rule")" == "README.md" ]] && continue
        cp "$rule" "$CLAUDE_RULES_DIR/"
        rules_copiadas=$((rules_copiadas + 1))
    done
    echo "Rules copiadas a $CLAUDE_RULES_DIR: $rules_copiadas desde $OBA_REVIEW_DIR"
else
    echo "oba no mounteado o review/ no existe — skip rules."
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
      "mcp__tuqui-adhoc__odoo_search_read",
      "mcp__tuqui-adhoc__odoo_read_group",
      "mcp__tuqui-adhoc__odoo_models_list",
      "mcp__tuqui-adhoc__odoo_search_count",
      "mcp__tuqui-adhoc__odoo_fields_get",
      "mcp__tuqui-adhoc__odoo_fields_batch",
      "mcp__tuqui-adhoc__odoo_schema_discover",
      "mcp__tuqui-adhoc__odoo_skills_directory",
      "mcp__tuqui-adhoc__odoo_skill_detail",
      "mcp__tuqui-adhoc__tuqui_context",
      "mcp__tuqui-adhoc__tuqui_guide"
    ]
  }
}
JSON
    echo "Allow-list base de Claude Code instalada en $CLAUDE_SETTINGS"
else
    echo "Claude Code settings.json ya existe — respeto config propia ($CLAUDE_SETTINGS)"
fi

if [[ "${R2_ENABLE_DEVOPS:-0}" == "1" ]]; then
    # kubectl
    if ! command -v kubectl &>/dev/null; then
        echo "Instalando kubectl..."
        KUBECTL_VERSION=$(curl -Ls https://dl.k8s.io/release/stable.txt)
        curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl \
            && chmod +x /tmp/kubectl && sudo mv /tmp/kubectl /usr/local/bin/kubectl \
            && echo "kubectl ${KUBECTL_VERSION} instalado." \
            || echo "FALLO: no se pudo instalar kubectl"
    else
        echo "kubectl ya presente ($(kubectl version --client -o json 2>/dev/null | grep gitVersion | head -1 || echo '?'))."
    fi

    # helm
    if ! command -v helm &>/dev/null; then
        echo "Instalando helm..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
            && echo "helm $(helm version --short 2>/dev/null) instalado." \
            || echo "FALLO: no se pudo instalar helm"
    else
        echo "helm ya presente ($(helm version --short 2>/dev/null))."
    fi

    # Docker CLI — DooD: el socket del host está montado en /var/run/docker.sock.
    # usermod no toma efecto en la sesión actual; chmod 666 cubre el acceso inmediato.
    if ! command -v docker &>/dev/null; then
        echo "Instalando Docker CLI..."
        sudo apt-get -qq update \
            && sudo apt-get -qq install -y --no-install-recommends docker.io \
            && echo "Docker CLI instalado." \
            || echo "FALLO: no se pudo instalar Docker CLI"
    else
        echo "docker ya presente ($(docker --version 2>/dev/null))."
    fi
    if [ -S /var/run/docker.sock ]; then
        DOCKER_SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
        if ! getent group docker &>/dev/null; then
            sudo groupadd -g "$DOCKER_SOCK_GID" docker
        elif [[ "$(getent group docker | cut -d: -f3)" != "$DOCKER_SOCK_GID" ]]; then
            sudo groupmod -g "$DOCKER_SOCK_GID" docker 2>/dev/null || true
        fi
        sudo usermod -aG docker odoo
        sudo chmod 666 /var/run/docker.sock
    fi

    # gcloud
    if ! command -v gcloud &>/dev/null; then
        echo "Instalando gcloud CLI..."
        sudo apt-get -qq update \
            && sudo apt-get -qq install -y --no-install-recommends apt-transport-https ca-certificates gnupg \
            && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
                | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
            && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
                | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list \
            && sudo apt-get -qq update \
            && sudo apt-get -qq install -y --no-install-recommends google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin \
            && echo "gcloud $(gcloud version --format='value(Google Cloud SDK)') instalado." \
            || echo "FALLO: no se pudo instalar gcloud"
    else
        echo "gcloud ya presente ($(gcloud version --format='value(Google Cloud SDK)' 2>/dev/null))."
    fi
fi

if [[ "${AD_DEV_MODE:-}" == "MASTER" ]]; then
    echo "Running in master mode"
    ~/.resources/entrypoint
fi

exit 0
