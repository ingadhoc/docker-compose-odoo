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

## Mounts auto-detectados de proyectos del ecosistema adhoc-way

Los proyectos del ecosistema (`devops`, `adhoc-way`, `tuqui`, `oba-project`, etc.) viven en paths host estables fuera de `custom/<version>/` y se exponen al devcontainer vía bind-mount. La detección es **automática**: `.devcontainer/scripts/discover-mounts.sh` corre en host antes de cada `docker compose up` (gatillado por `initializeCommand` en `devcontainer.json`), inspecciona qué paths del catálogo existen y regenera `docker-compose.auto-mounts.yml`.

**El catálogo lo declara `oba-project`**, no este repo: vive en `oba-project/.adhoc/topology.yml` (trabajo C — spec adhoc-way `estandarizacion-oba.md` §4). `discover-mounts.sh` lo lee desde el host (seed: `${HOME}/repositorios/oba-project`, overridable por env `OBA_PROJECT_HOST`); si no lo encuentra, no monta nada del ecosistema y avisa. Paths por defecto que declara el manifest hoy:

- `${HOME}/repositorios/devops/`              → `/home/odoo/custom/devops`
- `${HOME}/repositorios/adhoc-way/`           → `/home/odoo/custom/adhoc-way`
- `${HOME}/tuqui/`                            → `/home/odoo/custom/tuqui`
- `${HOME}/repositorios/oba-project/`         → `/home/odoo/custom/oba-project`
- `${HOME}/repositorios/odumbo/`              → `/home/odoo/custom/odumbo`
- `${HOME}/repositorios/consultoria-tecnica/` → `/home/odoo/custom/consultoria-tecnica`

Si tu repo del ecosistema vive en otro path (no-default) o querés mountear algo fuera del catálogo, usá `docker-compose.override.yml` (opt-in manual, gitignored).

`poststart.sh` corre adentro del container y registra los proyectos mounteados buscando `custom/<proyecto>/AGENTS.md` para listarlos en el AGENTS.md consolidado del workspace. No ejecuta código del proyecto automáticamente.

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
