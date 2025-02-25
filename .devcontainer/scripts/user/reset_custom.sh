#!/bin/bash

for app in "/home/odoo/custom/repositories/"*; do
    if [[ -d $app ]]; then
        app_name=$(basename $app)
        [[ $app_name == .* || $app_name == src* ]] && continue
        echo "Repo: $app_name"
        cd $app
        git checkout $ODOO_VERSION
        git fetch origin
        if [[ $(git rev-parse HEAD) == $(git rev-parse origin/$ODOO_VERSION) ]]; then
            echo "Already on $ODOO_VERSION"
            continue
        fi
        if [[ $(git status -s) ]]; then
            echo "Stashing changes"
            git stash
        fi
        git reset --hard origin/$ODOO_VERSION
        cd -
    fi
done
