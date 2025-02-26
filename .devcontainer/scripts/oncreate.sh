#!/bin/bash

if [ ! -L /home/odoo/custom/repositories/src ]; then
    ln -sf /home/odoo/src/ /home/odoo/custom/repositories/src
fi

exit
