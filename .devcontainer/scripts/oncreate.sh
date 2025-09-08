#!/bin/bash

echo "OnCreate"

# Ignore gitaggregate config in order to use the one from the host
rm -f /home/odoo/.gitconfig

# We bring the addons from src to custom/repositories/src and leave them as symbolic links
# so that Odoo can detect them as addons and we can use them in the container
rm -rf /home/odoo/custom/repositories/src
mkdir -p /home/odoo/custom/repositories/src
for app in "/home/odoo/src/"*; do
    if [[ -d $app ]]; then
        module_name=$(basename $app)
        ln -sf $app /home/odoo/custom/src/$module_name
        echo "Creating symlink for $module_name ln -sf $app /home/odoo/custom/src/$module_name"
    fi
done

exit 0
