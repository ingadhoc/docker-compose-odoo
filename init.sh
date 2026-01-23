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
    git update-index ${OPERATION} $SCRIPT_DIR/odools.toml
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
    fi

    if [[ "$ODOO_V" =~ ^[0-9]{2}$ ]]; then
        sed_inplace "s/^ODOO_MINOR=.*/ODOO_MINOR=$ODOO_V.0.dev/" "$SCRIPT_DIR/.env"
    fi

    if [[ "$ODOO_V" == "master" ]]; then
        sed_inplace "s/^ODOO_MINOR=.*/ODOO_MINOR=$ODOO_V.dev/" "$SCRIPT_DIR/.env"
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
