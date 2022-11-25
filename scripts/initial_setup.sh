#!/bin/bash
docker-compose -p traefik -f traefik.yml up -d
DIR="$(cd "$(dirname "$0")" && pwd)"
$DIR/link_volumes.sh