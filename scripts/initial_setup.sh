#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
$DIR/run_aeroo_docs.sh
$DIR/run_traefik.sh
$DIR/run_portainer.sh
$DIR/link_volumes.sh
$DIR/config_prompt.sh
