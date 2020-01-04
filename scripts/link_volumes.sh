#!/bin/bash
# change permissions so we can edit container files from host
# TODO chequear bien cual tenemos que dar
# chmod -R g+rw volumes/
# como no usamos con -p usamos el directorio como nombre de proyecto
docker_compose_project=${PWD##*/}
# le borramos los "." cosa que tmb hace docker-compose
docker_compose_project=${docker_compose_project//.}
# borramos enlace si ya existía
rm data/default 2> /dev/null
# creamos enlace
ln -s  /var/lib/docker/volumes/${docker_compose_project}_default/_data data/default
