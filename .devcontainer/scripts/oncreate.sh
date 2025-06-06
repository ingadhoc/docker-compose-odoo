#!/bin/bash

rm -f /home/odoo/.gitconfig

if [ ! -L /home/odoo/custom/repositories/src ]; then
    ln -sf /home/odoo/src/ /home/odoo/custom/repositories/src
fi

exit 0
