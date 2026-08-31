#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODOO_V=$(basename "$SCRIPT_DIR")

assume-unchanged() {
    local OPERATION="--assume-unchanged"
    if [[ $1 == "no" ]]; then
        OPERATION="--no-assume-unchanged"
    fi
    git update-index ${OPERATION} $SCRIPT_DIR/.devcontainer/.vscode/launch.json
    git update-index ${OPERATION} $SCRIPT_DIR/.devcontainer/scripts/oncreate.sh
    git update-index ${OPERATION} $SCRIPT_DIR/.devcontainer/devcontainer.json
    git update-index ${OPERATION} $SCRIPT_DIR/.env
    git update-index ${OPERATION} $SCRIPT_DIR/docker-compose.yml
    # To revert the changes, you can use:
    # git update-index --no-assume-unchanged .devcontainer/.vscode/launch.json
}

while getopts ":u|r|c" option; do
   case $option in
      u)
         assume-unchanged no
         exit;;
      r)
         assume-unchanged
         exit;;
      c)
         docker image prune -f
         exit;;
      *)
         echo "Invalid option"
         echo "Usage: $0 [-u | -r | -c]"
         echo "u: (unset ignored files) Unset assume-unchanged"
         echo "r: (restore ignored files) Set assume-unchanged"
         echo "c: (clean) Prune Docker images"
         exit 1;;
   esac
done

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed_inplace() {
        sed -i '' "$@"
    }
else
    sed_inplace() {
        sed -i "$@"
    }
fi

# PostgreSQL major used by each Odoo version, same map as production.
pg_major_for() {
    case "$1" in
        13|15) echo 13 ;;
        16)    echo 14 ;;
        17|18) echo 15 ;;
        19|20) echo 17 ;;
        # Newer versions follow the latest mapping, older ones keep PG 15.
        *) if [[ "$1" =~ ^[0-9]+$ ]] && [[ "$((10#$1))" -lt 19 ]]; then echo 15; else echo 17; fi ;;
    esac
}

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    # Check if "ODOO_V" is 2 digits or "master"
    if [[ "$ODOO_V" =~ ^[0-9]{2}$ ]] || [[ "$ODOO_V" == "master" ]]; then
        echo "Fixing env vars"
        sed_inplace "s/^DOMAIN=.*/DOMAIN=$ODOO_V.odoo.localhost/" "$SCRIPT_DIR/.env"
        sed_inplace "s/^ODOO_VERSION=.*/ODOO_VERSION=$ODOO_V/" "$SCRIPT_DIR/.env"
        if ! grep -qE "^ODOO_MINOR=${ODOO_V}\." "$SCRIPT_DIR/.env"; then
            sed_inplace "s/^ODOO_MINOR=.*/ODOO_MINOR=$ODOO_V.0.dev/" "$SCRIPT_DIR/.env"
        fi

        if [[ -n "$SKIP_CTX_PG" ]]; then
            echo "SKIP_CTX_PG set, leaving ODOO_PGHOST untouched"
        else
            PG_MAJOR=$(pg_major_for "$ODOO_V")
            PG_SERVICE="db${PG_MAJOR}"
            # PG 15 is the context's original `db`, kept under that name.
            [[ "$PG_MAJOR" == "15" ]] && PG_SERVICE="db"
            echo "Odoo $ODOO_V uses PostgreSQL $PG_MAJOR ($PG_SERVICE)"
        fi
    fi

    if [[ "$ODOO_V" == "master" ]]; then
        sed_inplace "s/^SERVER_WIDE_MODULES=/# SERVER_WIDE_MODULES=/" "$SCRIPT_DIR/.env"
        # sed_inplace "s/^IGNORE_SRC_REPOSITORIES=.*$/IGNORE_SRC_REPOSITORIES=True/" "$SCRIPT_DIR/.env"
        sed_inplace "s|/home/odoo/custom/repositories|/home/odoo/custom|g" "$SCRIPT_DIR/.devcontainer/devcontainer.json"
        sed_inplace "s|/home/odoo/custom/repositories|/home/odoo/custom|g" "$SCRIPT_DIR/.devcontainer/scripts/oncreate.sh"
        sed_inplace "s|\"AD_DEV_MODE\": \"NORMAL\"|\"AD_DEV_MODE\": \"MASTER\"|g" "$SCRIPT_DIR/.devcontainer/devcontainer.json"
        sed_inplace 's/"localRoot": "\${workspaceFolder}",/"localRoot": "${workspaceFolder}\/repositories",/' $SCRIPT_DIR/.devcontainer/.vscode/launch.json
        sed_inplace "s/ipv4_address:.*/ipv4_address: 172.60.0.99/" "$SCRIPT_DIR/docker-compose.yml"
        sed_inplace "s/^ODOO_MINOR=.*/ODOO_MINOR=$ODOO_V.dev/" "$SCRIPT_DIR/.env"
    fi

    if [[ "$ODOO_V" =~ ^[0-9]{2}$ ]] && [[ "$ODOO_V" -le "17" ]]; then
        echo "Disabling format on save for Odoo $ODOO_V"
        sed_inplace "s|\"editor.formatOnSave\": true,|\"editor.formatOnSave\": false,|g" "$SCRIPT_DIR/.devcontainer/devcontainer.json"
        perl -0777 -i -pe 's/"editor.codeActionsOnSave":\s*\{.*?\},/"editor.codeActionsOnSave": {"source.fixAll": "never", "source.organizeImports": "never"},/sg' "$SCRIPT_DIR/.devcontainer/devcontainer.json"
    fi

    # Transition to Odoo 20
    if [[ "$ODOO_V" == "20" ]]; then
        echo "Transitioning to Odoo 20"
        sed_inplace "s/^IGNORE_SRC_REPOSITORIES=.*/IGNORE_SRC_REPOSITORIES=True/" "$SCRIPT_DIR/.env"
        sed_inplace "s/^SERVER_WIDE_MODULES=.*/SERVER_WIDE_MODULES=/" "$SCRIPT_DIR/.env"
    fi

    echo "Pull latest image"
    source "$SCRIPT_DIR/.env"
    if [[ "$OSTYPE" == "darwin"* ]] && [[ "$(uname -m)" == "arm64" ]]; then
        docker pull --platform linux/amd64 ${ODOO_IMAGE}:${ODOO_MINOR}
    else
        docker pull ${ODOO_IMAGE}:${ODOO_MINOR}
    fi

fi

# PostgreSQL instance lives in the context repo, one per major. See README.
# Stops here on failure, before the steps that recreate the Odoo container.
if [[ -n "$PG_SERVICE" ]]; then
    CTX_DIR="${CTX_DIR:-$(dirname "$SCRIPT_DIR")/ctx}"
    if [[ ! -d "$CTX_DIR" ]]; then
        echo "ERROR: no context repo at $CTX_DIR. Set CTX_DIR if it lives elsewhere."
        exit 1
    fi
    echo "Starting $PG_SERVICE in the context repo ($CTX_DIR)"
    if ! ( cd "$CTX_DIR" && docker compose --profile "pg${PG_MAJOR}" up -d "$PG_SERVICE" ); then
        echo "ERROR: could not start $PG_SERVICE. Update the context repo (git pull) and rerun,"
        echo "       or set SKIP_CTX_PG=1 if you run PostgreSQL yourself."
        exit 1
    fi
    # Claimed only now, so a failure above leaves the .env untouched.
    # Namespaced so an exported libpq PGHOST cannot shadow it in compose.
    if grep -q "^ODOO_PGHOST=" "$SCRIPT_DIR/.env"; then
        sed_inplace "s/^ODOO_PGHOST=.*/ODOO_PGHOST=$PG_SERVICE/" "$SCRIPT_DIR/.env"
    else
        printf '\nODOO_PGHOST=%s\n' "$PG_SERVICE" >> "$SCRIPT_DIR/.env"
    fi
fi

# Auth + estado de CLIs de agentes — setup del "hop" dir local al repo
# (`.devcontainer/auth/`). docker-compose.yml mountea este dir al container;
# cada entry es un symlink (default → $HOME del dev = estado COMPARTIDO)
# o un dir real (opt-out → estado AISLADO en repo, controlado por el dev).
#
# Docker bind-mountea el target del symlink, así que efecto es idéntico a
# mount directo al host cuando default. docker-compose.yml queda agnóstico.
#
# Decisión: ADR 0023 en adhoc-way (mayo 2026) — supersede el dir separado
# `~/.adhoc-devcontainer-auth/shared/` que estableció spec 0012.

# 1. Ensure host paths exist (Docker los crearía como root si faltan).
#    Si el dev ya usó claude/codex/gh en el host, no toca.
mkdir -p \
    "$HOME/.claude" \
    "$HOME/.codex" \
    "$HOME/.gemini" \
    "$HOME/.agents" \
    "$HOME/.config/gh" \
    "$HOME/.adhoc"
if [ ! -f "$HOME/.claude.json" ]; then
    echo '{"hasCompletedOnboarding":true,"numStartups":5,"installMethod":"npm","autoUpdates":true}' \
        > "$HOME/.claude.json"
fi

# 2. Hop dir local al repo + symlinks default (compartido con host).
#    Si el dev quiere aislar un entry: borrar el symlink y crear dir/file
#    real en su lugar (`rm auth/.claude && mkdir auth/.claude`). Persiste
#    per-machine, no committable (gitignoreado).
HOP_DIR="$SCRIPT_DIR/.devcontainer/auth"
mkdir -p "$HOP_DIR/.config"
for item in .claude .codex .gemini .agents .claude.json; do
    if [ ! -e "$HOP_DIR/$item" ]; then
        ln -s "$HOME/$item" "$HOP_DIR/$item"
    fi
done
if [ ! -e "$HOP_DIR/.config/gh" ]; then
    ln -s "$HOME/.config/gh" "$HOP_DIR/.config/gh"
fi
echo "Auth hop listo: $HOP_DIR (symlinks default → \$HOME del dev)."

echo "Binding directory"
docker rm -f odoo-${ODOO_V} 2> /dev/null
rm -f "$SCRIPT_DIR/data/default" 2> /dev/null
docker volume rm -f ${ODOO_V}_default 2> /dev/null

if [[ "$OSTYPE" == "darwin"* ]] && [[ "$(uname -m)" == "arm64" ]]; then
    export DOCKER_DEFAULT_PLATFORM=linux/amd64
fi

docker compose create
VOLUME_MOUNTPOINT=$(docker volume inspect ${ODOO_V}_default 2> /dev/null | jq -r .[0].Mountpoint)
if [[ "$VOLUME_MOUNTPOINT" =~ ^/ ]]; then
    echo "Volume mountpoint detected: $VOLUME_MOUNTPOINT"
    ln -s $VOLUME_MOUNTPOINT "$SCRIPT_DIR/data/default"
    echo "Setting permissions"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: Use chmod instead of setfacl
        sudo chmod -R u+rwX $VOLUME_MOUNTPOINT
        sudo chmod u+rwX $(dirname "$VOLUME_MOUNTPOINT")
        sudo chmod u+rwX $(dirname $(dirname "$VOLUME_MOUNTPOINT"))
    else
        sudo setfacl -R -m u:$USER:rwX $VOLUME_MOUNTPOINT
        sudo setfacl -m u:$USER:rwX $(dirname "$VOLUME_MOUNTPOINT")
        sudo setfacl -m u:$USER:rwX $(dirname $(dirname "$VOLUME_MOUNTPOINT"))
    fi
fi

# Clean up dangling images
docker image prune -f

assume-unchanged
echo "Setup completed. You can now open this folder in VS Code and start the devcontainer."
