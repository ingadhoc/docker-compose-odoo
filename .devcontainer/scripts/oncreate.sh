#!/bin/bash

echo "OnCreate"

# Ignore gitaggregate config in order to use the one from the host
rm -f /home/odoo/.gitconfig

exit 0
