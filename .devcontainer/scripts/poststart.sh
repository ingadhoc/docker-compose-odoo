#!/bin/bash

# Fix addons paths
for app in "/home/odoo/custom/repositories/"*; do
    if [[ -d $app ]]; then
        for module in "$app/"*; do
            if [[ -d $module ]]; then
                module_name=$(basename $module)
                ln -sf "$module/" /home/odoo/src/odoo/odoo/addons/$module_name
                echo "odoo/addons/$module_name" >> /home/odoo/src/odoo/.git/info/exclude
            fi
        done
    fi
done
