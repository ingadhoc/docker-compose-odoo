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

Desde Odoo 20, cada versión corre contra el mismo major de PostgreSQL que usa en
producción. `init.sh` resuelve el major desde el nombre del directorio, escribe
`ODOO_PGHOST` en el `.env` y levanta esa instancia en el repo de context.

| Odoo | PG | `ODOO_PGHOST` | Puerto en el host |
| --- | --- | --- | --- |
| hasta 19 | 15 | `db` | 5432 |
| 20, master | 17 | `db17` | 5417 |

Las versiones anteriores a la 20 **no cambian**: siguen en el `db` compartido de
siempre, que es al que ya apuntan. La alineación arranca en la 20 a propósito —
retrofitear las viejas obligaría a mudar bases que ya funcionan, sin ganar nada.

Se llama `ODOO_PGHOST` y no `PGHOST` porque un `PGHOST` exportado en el shell del
dev (variable estándar de libpq) le gana al `.env` en la interpolación de compose
y mandaría el container a otro lado en silencio. Adentro del container la
variable llega igual como `PGHOST`.

Si el context no está en `~/odoo/ctx`, pasale el path: `CTX_DIR=/otro/path ./init.sh`.

Necesitás el repo de context actualizado — el service `db17` se agregó ahí. Si
`init.sh` no puede levantar la instancia corta con error, en vez de dejarte un
Odoo apuntando a un host que no existe; si corrés tu propio PostgreSQL,
`SKIP_CTX_PG=1 ./init.sh` no toca el `ODOO_PGHOST` del `.env` ni levanta nada.

Las instancias conviven, así que podés tener varias versiones levantadas a la
vez. Lo que **no** viaja entre majors son las bases: cada instancia tiene su
propio datadir. Las bases del `db` no se ven desde la 20 — no se tocan, siguen
ahí y en el puerto 5432, pero para usarlas del otro lado hay que mudarlas con
`pg_dump` / `pg_restore`. El detalle está en el
[readme del context](https://github.com/ingadhoc/docker-compose-context#postgresql-por-versión-de-odoo).

## Start devcontainer

```sh
devcontainer open ~/odoo/18
```

## Actualización automática al levantar el devcontainer

Cada `~/odoo/<version>` es un clone propio de este repo, así que cada uno
envejece por su cuenta: el que no abrís hace un mes se queda un mes atrás. Al
levantar el devcontainer, `.devcontainer/scripts/self-update.sh` corre en el
host (primer paso del `initializeCommand`) y pone al día **esa** versión, la
que estás abriendo — nunca las hermanas.

Hace dos cosas:

- **El clone.** `git fetch` del upstream de `main` y `git merge --ff-only`.
  Solo fast-forward: si tenés commits propios, si estás parado en otra rama o
  si el merge no es limpio, avisa y no toca nada.
- **La imagen.** `docker pull` de `${ODOO_IMAGE}:${ODOO_MINOR}`, a lo sumo una
  vez cada 24 h — el mtime del stamp `.devcontainer/.last-image-pull` es la
  ventana. Si la imagen cambió, avisa: puede hacer falta un *Rebuild
  Container* para que el container salga de la nueva.

Ninguna de las dos puede voltear el arranque: todo fallo (sin red, la llave
pide passphrase, el registry no responde) sale como warning y el devcontainer
levanta igual.

**Lo que no actualiza solo.** `init.sh` patchea por versión unos pocos
archivos (`.env`, `docker-compose.yml`, `devcontainer.json`, `oncreate.sh`,
`launch.json` — la lista vive en `.devcontainer/scripts/lib/managed-files.sh`)
y los marca `--assume-unchanged`. Si los commits nuevos tocan alguno, el
self-update **no mergea**: un fast-forward a secas te dejaría el `.env` de
upstream con el `DOMAIN` y el `ODOO_VERSION` de otra versión. Ahí te lo dice y
lo ponés al día vos, que es también la receta para destrabar un clone que
quedó muy atrás:

```sh
cd ~/odoo/19
./init.sh -u              # git vuelve a ver los archivos patcheados
git stash                 # guarda tus ediciones locales
git pull --ff-only
./init.sh                 # re-aplica la config de versión, pullea imagen y re-marca
git stash pop             # solo si tenías ediciones propias además del patch
```

Pasa poco: de 37 commits en 90 días, 6 tocaron alguno de esos archivos.

**Opt-out.** `SKIP_SELF_UPDATE=1` en el entorno del host no actualiza nada.
`SELF_UPDATE_IMAGE_MAX_AGE=<segundos>` cambia la ventana del pull de imagen
(`0` = pullear en cada arranque).

**Un clone que todavía no tiene el mecanismo** (clonado antes de esto) no se
actualiza solo la primera vez: corré la receta de arriba una vez y de ahí en
más se mantiene al día.

## Mounts auto-detectados de proyectos del ecosistema adhoc-way

Los proyectos del ecosistema (`devops`, `adhoc-way`, `oba`, etc.) viven en paths host estables fuera de `custom/<version>/` y se exponen al devcontainer vía bind-mount. La detección es **automática**: `.devcontainer/scripts/discover-mounts.sh` corre en host antes de cada `docker compose up` (segundo paso del `initializeCommand`, después del self-update), inspecciona qué paths del catálogo existen y regenera `docker-compose.auto-mounts.yml`.

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
