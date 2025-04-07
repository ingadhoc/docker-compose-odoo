#!/bin/bash

ODOO_V=$(basename $(pwd))

sed -i "s/^ODOO_MINOR=.*/ODOO_MINOR=$ODOO_V.0.dev/" .env
sed -i "s/^DOMAIN=.*/DOMAIN=$ODOO_V.odoo.localhost/" .env
sed -i "s/^ODOO_VERSION=.*/ODOO_VERSION=$ODOO_V/" .env
