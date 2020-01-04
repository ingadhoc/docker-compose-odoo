#!/bin/bash

# Chequear si no existe una línea 'dnsmasq' en NetworkManager.conf, agregar de ser asi.
grep -qxF 'dns=dnsmasq' /etc/NetworkManager/NetworkManager.conf || sed -i '/^\[main\].*/a dns=dnsmasq' /etc/NetworkManager/NetworkManager.conf
rm /etc/resolv.conf && sudo ln -s /var/run/NetworkManager/resolv.conf /etc/resolv.conf

# sh -c "echo 'address=/.loc/127.0.0.1' > /etc/NetworkManager/dnsmasq.d/local"
# Usamos la ip del gateway de docker para que los contenedores de odoo puedan ver
# a traefik ahi y eso nos sirva para laburar en odoo-saas
sh -c "echo 'address=/.loc/172.17.0.1' > /etc/NetworkManager/dnsmasq.d/local"
sh -c "echo 'listen-address=172.17.0.1' >> /etc/NetworkManager/dnsmasq.d/local"

# Reiniciar servicios para tomar cambios
systemctl reload NetworkManager
service docker restart
