#!/bin/bash
portainer_image=portainer/portainer
{ # try

    docker rm -f portainer

}
{ # try

    docker volume create portainer_data

}
docker pull $portainer_image
docker run \
  -d \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  -l traefik.port=9000 \
  -l traefik.enable=true \
  -l traefik.frontend.rule=Host:portainer.loc \
  --restart=always \
  --name="portainer" \
  $portainer_image \
  --no-auth
