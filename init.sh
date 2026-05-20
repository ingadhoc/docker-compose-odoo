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

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    # Check if "ODOO_V" is 2 digits or "master"
    if [[ "$ODOO_V" =~ ^[0-9]{2}$ ]] || [[ "$ODOO_V" == "master" ]]; then
        echo "Fixing env vars"
        sed_inplace "s/^DOMAIN=.*/DOMAIN=$ODOO_V.odoo.localhost/" "$SCRIPT_DIR/.env"
        sed_inplace "s/^ODOO_VERSION=.*/ODOO_VERSION=$ODOO_V/" "$SCRIPT_DIR/.env"
        if ! grep -qE "^ODOO_MINOR=${ODOO_V}\." "$SCRIPT_DIR/.env"; then
            sed_inplace "s/^ODOO_MINOR=.*/ODOO_MINOR=$ODOO_V.0.dev/" "$SCRIPT_DIR/.env"
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
    fi

    if [[ "$ODOO_V" =~ ^[0-9]{2}$ ]] && [[ "$ODOO_V" -le "17" ]]; then
        echo "Disabling format on save for Odoo $ODOO_V"
        sed_inplace "s|\"editor.formatOnSave\": true,|\"editor.formatOnSave\": false,|g" "$SCRIPT_DIR/.devcontainer/devcontainer.json"
        perl -0777 -i -pe 's/"editor.codeActionsOnSave":\s*\{.*?\},/"editor.codeActionsOnSave": {"source.fixAll": "never", "source.organizeImports": "never"},/sg' "$SCRIPT_DIR/.devcontainer/devcontainer.json"
    fi

    echo "Pull latest image"
    source "$SCRIPT_DIR/.env"
    if [[ "$OSTYPE" == "darwin"* ]] && [[ "$(uname -m)" == "arm64" ]]; then
        docker pull --platform linux/amd64 ${ODOO_IMAGE}:${ODOO_MINOR}
    else
        docker pull ${ODOO_IMAGE}:${ODOO_MINOR}
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
