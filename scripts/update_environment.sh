#!/bin/bash
docker-compose pull
docker-compose rm -f
project=${PWD##*/} && project=${project//-} && docker volume rm ${project}_default
