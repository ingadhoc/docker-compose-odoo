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

Los proyectos del ecosistema (`devops`, `adhoc-way`, `tuqui`, `oba-specs`, y el propio `docker-compose-odoo`) viven en paths host estables fuera de `custom/<version>/` y se exponen al devcontainer vía bind-mount. La detección es **automática**: `.devcontainer/scripts/discover-mounts.sh` corre en host antes de cada `docker compose up` (gatillado por `initializeCommand` en `devcontainer.json`), inspecciona qué paths del catálogo existen y regenera `docker-compose.auto-mounts.yml`.

Convención de paths host por defecto (catálogo embebido en `discover-mounts.sh`):

- `${HOME}/repositorios/devops/`    → `/home/odoo/custom/devops`
- `${HOME}/repositorios/adhoc-way/` → `/home/odoo/custom/adhoc-way`
- `${HOME}/tuqui/`                  → `/home/odoo/custom/tuqui`
- `${HOME}/repositorios/oba-specs/` → `/home/odoo/custom/oba-specs`
- `<self>` (este repo)              → `/home/odoo/custom/devops/docker-compose-odoo` (requiere `devops` presente)

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

## Repos en custom/repositories/

Para trabajar con el código local de un repositorio en lugar del bakeado en la imagen, clonalo en `~/custom/repositories/`.

Si el repo tiene **comandos CLI de Odoo** (como `odoo fixdb`), usá el **mismo nombre que tiene en la imagen** (por ejemplo `ingadhoc-odoo-saas`, no `odoo-saas`). El script `400-auto-detect-addons` deduplica repos por nombre de directorio; si los nombres difieren, ambos quedan en el `addons_path` y el baked pisa al local para los comandos CLI. Para repos sin comandos CLI (solo modelos, vistas, etc.) no hay restricción de nombrado.
