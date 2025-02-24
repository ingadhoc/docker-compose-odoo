#!/bin/bash

# Fix addons paths
for app in "/home/odoo/custom/repositories/"*; do
    if [[ -d $app ]]; then
        app_name=$(basename $app)
        [[ $app_name == .* || $app_name == src* ]] && continue
        echo "App: $app_name"
        for module in "$app/"*; do
            if [[ -d $module ]]; then
                module_name=$(basename $module)
                [[ $module_name == .* || $module_name == src* ]] && continue
                echo "ln -sf $module/ /home/odoo/src/odoo/odoo/addons/$module_name"
                if [ ! -L /home/odoo/src/odoo/odoo/addons/$module_name ]; then
                    ln -sf $module/ /home/odoo/src/odoo/odoo/addons/$module_name
                fi
                echo "odoo/addons/$module_name" >> /home/odoo/src/odoo/.git/info/exclude
            fi
        done
    fi
done
