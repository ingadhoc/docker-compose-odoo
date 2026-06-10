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

Los proyectos del ecosistema (`devops`, `adhoc-way`, `tuqui`, `oba-project`, `oba-project-memory`, etc.) viven en paths host estables fuera de `custom/<version>/` y se exponen al devcontainer vía bind-mount. La detección es **automática**: `.devcontainer/scripts/discover-mounts.sh` corre en host antes de cada `docker compose up` (gatillado por `initializeCommand` en `devcontainer.json`), inspecciona qué paths del catálogo existen y regenera `docker-compose.auto-mounts.yml`.

El catálogo es config de **este** devcontainer (qué repos del ecosistema conviene montar al lado) y vive hardcodeado en `discover-mounts.sh`. Convención de paths host por defecto:

- `${HOME}/repositorios/devops/`              → `/home/odoo/custom/devops`
- `${HOME}/repositorios/adhoc-way/`           → `/home/odoo/custom/adhoc-way`
- `${HOME}/tuqui/`                            → `/home/odoo/custom/tuqui`
- `${HOME}/repositorios/oba-project/`         → `/home/odoo/custom/oba-project`
- `${HOME}/repositorios/oba-project-memory/`  → `/home/odoo/custom/oba-project-memory`
- `${HOME}/repositorios/odumbo/`              → `/home/odoo/custom/odumbo`
- `${HOME}/repositorios/consultoria-tecnica/` → `/home/odoo/custom/consultoria-tecnica`

Si tu repo del ecosistema vive en otro path (no-default) o querés mountear algo fuera del catálogo, usá `docker-compose.override.yml` (opt-in manual, gitignored).

`poststart.sh` corre adentro del container y registra los proyectos mounteados buscando `custom/<proyecto>/AGENTS.md` para listarlos en el AGENTS.md consolidado del workspace. No ejecuta código del proyecto automáticamente.

Spec: [ingadhoc/adhoc-way#99 — aplicar adhoc-way al ecosistema OBA](https://github.com/ingadhoc/adhoc-way/pull/99) (decisiones §6 #11-#15). Sin compatibilidad hacia atrás con el modelo viejo `custom/<proyecto>-ctx/`.

## Repos en custom/repositories/

Para trabajar con el código local de un repositorio en lugar del bakeado en la imagen, clonalo en `~/custom/repositories/`.

Si el repo tiene **comandos CLI de Odoo** (como `odoo fixdb`), usá el **mismo nombre que tiene en la imagen** (por ejemplo `ingadhoc-odoo-saas`, no `odoo-saas`). El script `400-auto-detect-addons` deduplica repos por nombre de directorio; si los nombres difieren, ambos quedan en el `addons_path` y el baked pisa al local para los comandos CLI. Para repos sin comandos CLI (solo modelos, vistas, etc.) no hay restricción de nombrado.
