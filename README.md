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

## Opt-in mounts de proyectos del ecosistema adhoc-way

Los proyectos del ecosistema (`devops`, `adhoc-way`, `tuqui`) viven en paths host estables fuera de `custom/<version>/` y se exponen al devcontainer vía bind-mount opt-in. Cada dev decide qué proyectos quiere ver montados.

**Cómo activarlo:**

```sh
cp docker-compose.override.yml.example docker-compose.override.yml
# editar, descomentar los mounts que necesites
```

Convención de paths host por defecto:

- `${HOME}/repositorios/devops/`    → `/home/odoo/custom/devops`
- `${HOME}/repositorios/adhoc-way/` → `/home/odoo/custom/adhoc-way`
- `${HOME}/tuqui/`                  → `/home/odoo/custom/tuqui` (extra)

`poststart.sh` detecta automáticamente los proyectos mounteados buscando `custom/<proyecto>/AGENTS.md` y los lista en `custom/AGENTS.md` consolidado del workspace. No ejecuta código del proyecto automáticamente (opt-in explícito si emerge necesidad — ver `for_each_mounted_project` en poststart.sh).

Spec: [ingadhoc/adhoc-way#99 — aplicar adhoc-way al ecosistema OBA](https://github.com/ingadhoc/adhoc-way/pull/99) (decisiones §6 #11-#15). Sin compatibilidad hacia atrás con el modelo viejo `custom/<proyecto>-ctx/`.

## Odoo source code

Inside the devcontainer you have available a "src" folder that is a link to src folder inside the container.

if you want to use this folder outside the container you need:

- uncomment the volume (file: docker-compose.yaml)

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
