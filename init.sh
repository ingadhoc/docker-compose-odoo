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

echo "Binding directory"
rm -f "$SCRIPT_DIR/data/default" 2> /dev/null
sudo setfacl -R -m u:$USER:rwX /var/lib/docker/volumes/${ODOO_V}_default
ln -s /var/lib/docker/volumes/${ODOO_V}_default/_data "$SCRIPT_DIR/data/default"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    echo "Pull latest image"
    source "$SCRIPT_DIR/.env"
    docker pull ${ODOO_IMAGE}:${ODOO_MINOR}
fi
