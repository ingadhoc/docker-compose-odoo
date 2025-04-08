#!/bin/bash

ODOO_V=$(basename $(pwd))

sed -i "s/^ODOO_MINOR=.*/ODOO_MINOR=$ODOO_V.0.dev/" .env
sed -i "s/^DOMAIN=.*/DOMAIN=$ODOO_V.odoo.localhost/" .env
sed -i "s/^ODOO_VERSION=.*/ODOO_VERSION=$ODOO_V/" .env

rm -f data/default 2> /dev/null
ln -s  /var/lib/docker/volumes/${ODOO_V}_default/_data data/default

# sudo setfacl -R -d -m u:$USER:rw-x /var/lib/docker/volumes/
