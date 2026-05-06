#!/bin/bash

echo "OnCreate"

# Ignore gitaggregate config in order to use the one from the host
rm -f /home/odoo/.gitconfig

# Limpiar custom/repositories/src/ si quedó de una versión anterior del setup
# (el loop de symlinks se eliminó — los addons baked ya están en addons_path via src/repositories/)
rm -rf /home/odoo/custom/repositories/src

# Crear workspace dir antes de que VS Code lo necesite como workspaceFolder.
# El contenido (symlinks) se construye en poststart.sh via build_workspace().
mkdir -p /home/odoo/workspace

exit 0
