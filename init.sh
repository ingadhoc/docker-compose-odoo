#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODOO_V=$(basename "$SCRIPT_DIR")

# Check if "ODOO_V" is 2 digits
if [[ "$ODOO_V" =~ ^[0-9]{2}$ ]] && [[ -f "$SCRIPT_DIR/.env" ]]; then
    echo "Fixing env vars"
    sed -i "s/^ODOO_MINOR=.*/ODOO_MINOR=$ODOO_V.0.dev/" "$SCRIPT_DIR/.env"
    sed -i "s/^DOMAIN=.*/DOMAIN=$ODOO_V.odoo.localhost/" "$SCRIPT_DIR/.env"
    sed -i "s/^ODOO_VERSION=.*/ODOO_VERSION=$ODOO_V/" "$SCRIPT_DIR/.env"
fi

if [[ "$ODOO_V" == "master" ]]; then
    echo "Fixing env vars"
    # TODO: Update the ODOO_MINOR to master.dev when be ready
    # sed -i "s/^ODOO_MINOR=.*/ODOO_MINOR=$ODOO_V.0.dev/" "$SCRIPT_DIR/.env"
    sed -i "s/^SERVER_WIDE_MODULES=/# SERVER_WIDE_MODULES=/" "$SCRIPT_DIR/.env"
    sed -i "s/^IGNORE_SRC_REPOSITORIES=.*$/IGNORE_SRC_REPOSITORIES=True/" "$SCRIPT_DIR/.env"
    sed -i "s/^DOMAIN=.*/DOMAIN=$ODOO_V.odoo.localhost/" "$SCRIPT_DIR/.env"
    sed -i "s/^ODOO_VERSION=.*/ODOO_VERSION=99/" "$SCRIPT_DIR/.env"

    sed -i "s|/home/odoo/custom/repositories|/home/odoo/custom|g" "$SCRIPT_DIR/.devcontainer/devcontainer.json"
    sed -i "s|\"AD_DEV_MODE\": \"NORMAL\"|\"AD_DEV_MODE\": \"MASTER\"|g" "$SCRIPT_DIR/.devcontainer/devcontainer.json"
fi

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    echo "Pull latest image"
    source "$SCRIPT_DIR/.env"
    docker pull ${ODOO_IMAGE}:${ODOO_MINOR}
fi

echo "Binding directory"
docker rm -f odoo-${ODOO_V} 2> /dev/null
rm -f "$SCRIPT_DIR/data/default" 2> /dev/null
docker volume rm -f ${ODOO_V}_default 2> /dev/null
docker compose create
VOLUME_MOUNTPOINT=$(docker volume inspect ${ODOO_V}_default 2> /dev/null | jq -r .[0].Mountpoint)
if [[ "$VOLUME_MOUNTPOINT" =~ ^/ ]]; then
    echo "Volume mountpoint detected: $VOLUME_MOUNTPOINT"
    ln -s $VOLUME_MOUNTPOINT "$SCRIPT_DIR/data/default"
    echo "Setting permissions"
    sudo setfacl -R -m u:$USER:rwX $VOLUME_MOUNTPOINT
    sudo setfacl -m u:$USER:rwX $(dirname "$VOLUME_MOUNTPOINT")
    sudo setfacl -m u:$USER:rwX $(dirname $(dirname "$VOLUME_MOUNTPOINT"))
fi
