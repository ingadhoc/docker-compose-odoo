# Odoo Docker Compose

devcointainer focoused on easing development

## Odoo Docker Adhoc

You can find documentation [here](https://docs.google.com/document/d/1nuX99v_ncfEfXlAAYVe85k9a1JbkXBVG_39GK5GGWzg/preview)

## Context

This must run with "developer context project" [docker-compose-context](git@github.com:ingadhoc/docker-compose-context.git)

```sh
cd ~/odoo
git clone git@github.com:ingadhoc/docker-compose-context.git ctx
cd ctx
./init.sh
```

## Start devcontainer

```sh
devcontainer open ~/odoo/18
```

## Odoo source code

Inside the devcontainer you have available a "src" folder that is a link to src folder inside the container.

if you want to use this folder outside the container you need:

- uncoment the volume

```yaml
services:
  odoo:
    volumes:
      # - default:/home/odoo/src
```

- fix permissions

```sh
~/odoo/18/ $: ./scripts/link_volumes.sh
```
