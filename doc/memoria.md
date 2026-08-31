# Memoria: language servers y techo del container

El devcontainer corre dos language servers que indexan todos los addons
paths: **Pylance** y el **Odoo LS** (extensión `Odoo.odoo`). Con decenas
de repos en `addons_paths` son unos 20k archivos `.py`, y el working set
de ambos crece de forma monotónica — lo que se analiza entra al índice y
no sale.

Medido en un devcontainer de 19.0 tras un día de uso:

| Proceso | RSS | En swap |
| --- | --- | --- |
| Pylance | 2.9 GB | 4.7 GB |
| Odoo LS | 4.7 GB | 0 |

Con varios devcontainers abiertos a la vez, sumado al navegador y al
VS Code del host, la máquina se queda sin RAM: empieza a paginar contra
disco y se congela. Cuando el kernel finalmente interviene, mata lo que
tenga el `oom_score` más alto — que suele ser el navegador, porque Chrome
se auto-asigna `oom_score_adj=100` para ser la primera víctima.

Hay tres capas para esto, independientes. La primera viene por default;
las otras dos son opt-in del dev.

## 1. Watchdog de language servers (por default)

`.devcontainer/scripts/ls-watchdog.sh`, lanzado desde `postStartCommand`.

Cada 60s compara `memory.current` del cgroup del container contra su
techo. Si pasa el 85%, manda `SIGTERM` al language server más pesado.
VS Code lo relanza solo, con el índice limpio.

Solo toca Pylance y el Odoo LS: procesos que VS Code sabe relanzar y cuyo
único estado es un índice regenerable. Nunca Odoo, postgres, shells ni
agentes. Tiene cooldown de 10 min para no matarlo mientras re-indexa, y
no actúa si el candidato más grande pesa menos de 1 GB.

El techo sale del cgroup del container si tiene `mem_limit`; si no, de una
fracción de la RAM del host (35% por default), para que escale entre
máquinas. Soporta cgroup v2 (`memory.current` / `memory.max`) y v1
(`memory/memory.usage_in_bytes` / `memory.limit_in_bytes`); si no puede
leer ninguno, lo dice en el log y sale en vez de quedarse mudo.

El `sleep 2` del hook en `devcontainer.json` no es cosmético. El exec del
devcontainer corre con TTY y lo desarma apenas retorna el último comando; sin
esa pausa el proceso en background no llega a ejecutarse y el watchdog nunca
arranca — silenciosamente, porque el hook igual reporta éxito. Verificado:
con TTY y sin pausa no arranca; con TTY y `sleep 1` arranca y sobrevive.

Log en `/tmp/ls-watchdog.log`:

```
2026-08-27 17:06:57  container al 88% (12707MB de 14336MB) — SIGTERM a pylance pid=2608 (5067MB)
2026-08-27 17:06:57    -> señalizado; VS Code lo relanza
```

Se ajusta por variables de entorno: `LS_WATCHDOG_INTERVAL`,
`LS_WATCHDOG_THRESHOLD_PCT`, `LS_WATCHDOG_FALLBACK_PCT`,
`LS_WATCHDOG_COOLDOWN`, `LS_WATCHDOG_MIN_VICTIM_MB`, `LS_WATCHDOG_LOG`.
Para desactivarlo, sacá la entrada `ls-watchdog` del `postStartCommand`.

## 2. Techo de memoria del container (opt-in)

Sin `mem_limit`, el container puede consumir toda la RAM del host. Medido
en un caso real: `memory.peak` de 20.77 GB en una máquina de 38 GB.

Como el valor depende de cuánta RAM tenga cada máquina, no viene puesto.
Para activarlo, creá `docker-compose.override.yml` en la raíz del repo
(está gitignoreado):

```yaml
services:
  odoo:
    mem_limit: 16g
    memswap_limit: 16g
```

`memswap_limit` igual a `mem_limit` impide que el container use swap del
host, que es lo que produce el congelamiento.

Después agregá el archivo a `dockerComposeFile` en tu
`.devcontainer/devcontainer.json` local:

```jsonc
"dockerComposeFile": [
  "../docker-compose.yml",
  "../docker-compose.auto-mounts.yml",
  "../docker-compose.override.yml"
],
```

Ese cambio **no se commitea**: `docker-compose.override.yml` está
gitignoreado, y declarar un `-f` que no existe hace fallar el arranque
del devcontainer para quien no lo tenga. `devcontainer.json` está marcado
con `assume-unchanged`, así que la edición local no ensucia `git status`.

Toma efecto en el próximo rebuild. Para verificar:

```bash
docker exec <container> cat /sys/fs/cgroup/memory.max
```

## 3. earlyoom en el host (opt-in, fuera de este repo)

Las dos capas anteriores viven adentro del container. Si el host se queda
sin RAM por otra razón, sigue sin haber nada que intervenga antes del
thrashing.

[earlyoom](https://github.com/rfjakob/earlyoom) mata el proceso más grande
cuando la RAM libre baja de un umbral, antes de que el kernel empiece a
paginar. En Debian/Ubuntu: `sudo apt install earlyoom`.

Tres detalles que hacen la diferencia entre que sirva y que no. Los tres
salen de correrlo cuatro días en una workstation real:

- **`-s 100`.** Por default earlyoom actúa solo si RAM *y* swap están ambos
  bajo el umbral. En una máquina con swap grande esa condición no se cumple
  antes del thrashing, así que nunca dispara. `-s 100` le dice que decida
  solo por RAM disponible.
- **`--avoid` con los procesos de contenido del navegador, no solo el
  principal.** El regex matchea contra `/proc/PID/comm` truncado a 15 chars,
  **no** contra el cmdline. Los procesos de contenido de Firefox no se llaman
  `firefox`: son `Isolated Web Co`, `Web Content`, `Privileged Cont`. Una
  lista que solo tenga `firefox|firefox-bin` los deja desprotegidos.
- **`--prefer` para el language server.** Podría parecer redundante — el
  `oom_score` ya crece con el consumo — pero no lo es: los navegadores se
  auto-asignan `oom_score_adj` alto (Chrome 100-300, Firefox 200) y eso pesa
  más que varios GB de RSS. Medido: un `Web Content` de 70 MiB puntuó 822
  mientras un `odoo_ls_server` de 9952 MiB puntuaba 814. Sin `--prefer`,
  earlyoom elige la pestaña de 70 MiB, no libera nada y vuelve a disparar en
  cascada.

`odoo_ls_server` sí va en `--prefer`; Pylance no, aunque también crezca: su
`comm` es `MainThread`, que comparte con el server de VS Code y los extension
hosts, y darle prioridad arriesga matar la sesión remota. A Pylance lo cubre
el watchdog del devcontainer, que lo identifica por cmdline.

```
EARLYOOM_ARGS="-m 12,6 -s 100 -r 300 --prefer '^odoo_ls_server$' --avoid '^(chrome|chrome_crashpad|firefox|firefox-bin|Isolated.Web.Co|Isolated.Servic|Web.Content|Privileged.Cont|WebExtensions|RDD.Process|Utility.Process|Socket.Process|code|Xorg|gnome-shell|systemd|sshd|dockerd|containerd|postgres)$'"
```

Los puntos reemplazan espacios para no depender de cómo systemd parsea las
comillas del `EnvironmentFile`. Después de aplicar, conviene confirmar que los
argumentos expandieron en un solo argv:

```bash
tr '\0' '\n' < /proc/$(systemctl show earlyoom -p MainPID --value)/cmdline
```
