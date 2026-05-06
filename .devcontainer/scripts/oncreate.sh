#!/bin/bash

echo "OnCreate"

# Ignore gitaggregate config in order to use the one from the host
rm -f /home/odoo/.gitconfig

# Limpiar custom/repositories/src/ si quedó de una versión anterior del setup
# (el loop de symlinks se eliminó — los addons baked ya están en addons_path via src/repositories/)
rm -rf /home/odoo/custom/repositories/src


exit 0
