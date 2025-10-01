#!/bin/bash

echo "OnCreate"

# Ignore gitaggregate config in order to use the one from the host
rm -f /home/odoo/.gitconfig

# Remove src folder if it exists
rm -rf "/home/odoo/custom/repositories/src"

exit 0
