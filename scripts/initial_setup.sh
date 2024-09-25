#!/bin/bash

# Create adhoc network if it doesn't exist
if ! docker network inspect adhoc > /dev/null 2>&1; then
  docker network create --subnet=172.40.0.0/16 adhoc
fi

# Start traefik
docker compose -p traefik -f traefik.yml up -d

# Link volumes
DIR="$(cd "$(dirname "$0")" && pwd)"
$DIR/link_volumes.sh
