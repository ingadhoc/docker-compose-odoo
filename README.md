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

## PostgreSQL

Cada versión de Odoo corre contra el mismo major de PostgreSQL que usa en
producción. `init.sh` resuelve el major desde el nombre del directorio, escribe
`ODOO_PGHOST` en el `.env` y levanta esa instancia en el repo de context
(`ODOO_PGHOST` y no `PGHOST` porque un `PGHOST` exportado en el shell del dev le
gana al `.env` en la interpolación de compose):

| Odoo | PG | `ODOO_PGHOST` | Puerto en el host |
| --- | --- | --- | --- |
| 13, 15 | 13 | `db13` | 5413 |
| 16 | 14 | `db14` | 5414 |
| 17, 18 | 15 | `db` | 5432 |
| 19, 20, master | 17 | `db17` | 5417 |

Una versión no listada se resuelve por número: de 19 en adelante sigue el mapeo
más nuevo (PG 17), y una anterior se queda en el `db` compartido, que es el que
ya usa hoy.

Si el context no está en `~/odoo/ctx`, pasale el path: `CTX_DIR=/otro/path ./init.sh`.

Necesitás el repo de context actualizado — los services por major se agregaron
ahí. Si `init.sh` no puede levantar la instancia corta con error, en vez de
dejarte un Odoo apuntando a un host que no existe; si corrés tu propio
PostgreSQL, `SKIP_CTX_PG=1 ./init.sh` no toca el `ODOO_PGHOST` del `.env` ni
levanta nada.

Las instancias conviven, así que podés tener varias versiones de Odoo levantadas
a la vez. Lo que **no** viaja entre majors son las bases: cada instancia tiene su
propio datadir. Si venís de una versión que apuntaba a otro major, las bases
viejas siguen intactas en la instancia anterior pero no las ves desde Odoo — hay
que mudarlas con `pg_dump` / `pg_restore`. El detalle está en el
[readme del context](https://github.com/ingadhoc/docker-compose-context#postgresql-por-versión-de-odoo).

## Start devcontainer

```sh
devcontainer open ~/odoo/18
```

## Mounts auto-detectados de proyectos del ecosistema adhoc-way

Los proyectos del ecosistema (`devops`, `adhoc-way`, `oba`, etc.) viven en paths host estables fuera de `custom/<version>/` y se exponen al devcontainer vía bind-mount. La detección es **automática**: `.devcontainer/scripts/discover-mounts.sh` corre en host antes de cada `docker compose up` (gatillado por `initializeCommand` en `devcontainer.json`), inspecciona qué paths del catálogo existen y regenera `docker-compose.auto-mounts.yml`.

El catálogo es config de **este** devcontainer (qué repos del ecosistema conviene montar al lado) y vive hardcodeado en `discover-mounts.sh`. Convención de paths host por defecto:

- `${HOME}/repositorios/devops/`              → `/home/odoo/custom/devops`
- `${HOME}/repositorios/devops-it/`           → `/home/odoo/custom/devops-it`
- `${HOME}/repositorios/adhoc-way/`           → `/home/odoo/custom/adhoc-way`
- `${HOME}/repositorios/oba/`                 → `/home/odoo/custom/oba`
- `${HOME}/repositorios/odumbo/`              → `/home/odoo/custom/odumbo`
- `${HOME}/repositorios/consultoria-tecnica/` → `/home/odoo/custom/consultoria-tecnica`

Si un proyecto del catálogo no está clonado en el host, `discover-mounts.sh` lo clona (la URL viaja en el catálogo); si el clone falla, avisa y sigue sin ese mount.

Algunos proyectos tienen **componentes**: repos que se clonan *adentro* del clone del proyecto y viajan con su mount, sin ser entrada propia del catálogo. Hoy hay uno — `oba/digest/` (repo `ingadhoc/oba-project-memory`, la wiki de módulos y productos), gitignoreado en el hub. `discover-mounts.sh` también lo clona si falta.

Si tu repo del ecosistema vive en otro path (no-default) o querés mountear algo fuera del catálogo, usá `docker-compose.override.yml` (opt-in manual, gitignored).

`poststart.sh` corre adentro del container y registra los proyectos mounteados buscando `custom/<proyecto>/AGENTS.md` para listarlos en `custom/workspace-map.md` (el `AGENTS.md` del workspace es la parte fija versionada en `oba-project`, symlinkeada por el mismo script). No ejecuta código del proyecto automáticamente.

Spec: [ingadhoc/adhoc-way#99 — aplicar adhoc-way al ecosistema OBA](https://github.com/ingadhoc/adhoc-way/pull/99) (decisiones §6 #11-#15). Sin compatibilidad hacia atrás con el modelo viejo `custom/<proyecto>-ctx/`.

## Repos en custom/repositories/

Para trabajar con el código local de un repositorio en lugar del bakeado en la imagen, clonalo en `~/custom/repositories/`.

Si el repo tiene **comandos CLI de Odoo** (como `odoo fixdb`), usá el **mismo nombre que tiene en la imagen** (por ejemplo `ingadhoc-odoo-saas`, no `odoo-saas`). El script `400-auto-detect-addons` deduplica repos por nombre de directorio; si los nombres difieren, ambos quedan en el `addons_path` y el baked pisa al local para los comandos CLI. Para repos sin comandos CLI (solo modelos, vistas, etc.) no hay restricción de nombrado.
