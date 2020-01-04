#!/bin/bash
traefik_image=traefik:1.7-alpine
{ # try

    docker rm -f traefik

}
docker pull $traefik_image
docker run -d \
    -p 80:80 \
    -p 8080:8080 \
    -l traefik.port=8080 \
    -l traefik.enable=true \
    -l traefik.frontend.rule=Host:traefik.loc \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --name="traefik" \
    --restart=always \
    $traefik_image \
    --api --docker --docker.domain=loc --docker.exposedbydefault=false
