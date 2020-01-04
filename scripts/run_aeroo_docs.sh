#!/bin/bash
aeroo_docs_image=adhoc/aeroo-docs
{ # try

    docker rm -f aeroo

}
docker pull $aeroo_docs_image
docker run --name="aeroo" --restart=always -d $aeroo_docs_image
