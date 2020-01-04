#!/bin/bash
cleanup_image=meltwater/docker-cleanup:latest
{ # try

    docker rm -f cleanup

}
docker pull $cleanup_image
# if we enable this orphan volumes are deleted and we don't want that
# because exited odoo container leaves orphan volumes
# -v /var/lib/docker:/var/lib/docker:rw \
docker run \
  -d \
  -e KEEP_IMAGES="postgres, adhoc/odoo-ar-e, adhoc/aeroo-docs" \
  -e CLEAN_PERIOD=7200 \
  -e DELAY_TIME=7200 \
  -v /var/run/docker.sock:/var/run/docker.sock:rw \
  --restart=always \
  --name="cleanup" \
  $cleanup_image
