#!/bin/bash
docker-compose -p global -f global.yml up -d
DIR="$(cd "$(dirname "$0")" && pwd)"
$DIR/link_volumes.sh
$DIR/config_prompt.sh
