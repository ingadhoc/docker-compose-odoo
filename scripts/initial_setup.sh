#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
$DIR/run_aeroo_docs.sh
$DIR/run_traefik.sh
#$DIR/run_cleanup.sh
$DIR/run_portainer.sh
# last because it restart networking and docker wont listen
$DIR/setup_dnsmasq.sh
$DIR/link_volumes.sh
$DIR/config_prompt.sh
