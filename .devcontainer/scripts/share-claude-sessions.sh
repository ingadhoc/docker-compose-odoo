#!/bin/bash
# Comparte sesiones de Claude Code host↔container creando symlinks de los
# nombres encoded del container hacia los del host. Idempotente, corre rápido.
#
# Claude encoda el path absoluto del workspace en el nombre del dir bajo
# ~/.claude/projects/. Host (/home/<user>/odoo/<v>/data/custom/<rest>) y
# container (/home/odoo/custom/<rest>) encodean distinto:
#   Host:      -home-<user>-odoo-<v>-data-custom(-<rest>)?
#   Container: -home-odoo-custom(-<rest>)?
#
# Esta función crea symlinks <container-encoded> → <host-encoded> para que
# `/resume` adentro del container vea sesiones creadas en el host (y las
# nuevas, post-symlink, son bidireccionales: caen en el dir real del host
# vía el symlink).
#
# Skipea si el destino ya existe (real o symlink) para no pisar data.
# Se ejecuta en postCreateCommand (vía poststart.sh) y postStartCommand
# (vía devcontainer.json), así proyectos nuevos abiertos en el host entre
# rebuilds o restarts del container quedan al día sin overhead.
#
# Ver ADR 0023 en adhoc-way para el contexto del bind mount host↔container.

set -euo pipefail

PROJECTS_DIR="$HOME/.claude/projects"
[ -d "$PROJECTS_DIR" ] || exit 0

linked=0
merged=0
warned=0
for host_proj in "$PROJECTS_DIR"/*; do
    [ -d "$host_proj" ] || continue
    [ -L "$host_proj" ] && continue
    host_name="$(basename "$host_proj")"

    # Match: -home-<user>-odoo-<version>-data-custom(-<rest>)?
    # Tanto top-level (`-data-custom`) como subdirs (`-data-custom-foo`).
    case "$host_name" in
        -home-*-odoo-*-data-custom|-home-*-odoo-*-data-custom-*)
            # `<rest>` incluye su `-` líder, o queda vacío si es top-level
            rest="${host_name#*-data-custom}"
            container_name="-home-odoo-custom${rest}"
            [ "$host_name" = "$container_name" ] && continue

            container_path="$PROJECTS_DIR/$container_name"

            # Caso 1: ya es symlink → idempotente, skip.
            if [ -L "$container_path" ]; then
                continue
            fi

            # Caso 2: existe como dir real (container creó sessions ahí
            # antes de tener el symlink). Mergear contenido al dir del host
            # y eliminar el dir real, después crear el symlink. No hay caso
            # donde priorizaríamos sessions del container sobre las del
            # host compartido — siempre queremos symlink.
            if [ -d "$container_path" ]; then
                # `mv -n` (no-clobber) evita pisar archivos del host. En la
                # práctica los SESSION-ID.jsonl son únicos, no debería haber
                # colisiones. Si alguna queda, rmdir falla y el script avisa.
                mv -n "$container_path"/* "$host_proj"/ 2>/dev/null || true
                mv -n "$container_path"/.[!.]* "$host_proj"/ 2>/dev/null || true
                if rmdir "$container_path" 2>/dev/null; then
                    merged=$((merged + 1))
                else
                    echo "share-claude-sessions: WARN — $container_path tiene archivos en conflicto con $host_proj, no se mergeó. Revisar manual." >&2
                    warned=$((warned + 1))
                    continue
                fi
            fi

            # Caso 3 (o post-merge): crear symlink. `--` separa flags porque
            # $host_name empieza con `-` y ln lo trataría como opción.
            ln -s -- "$host_name" "$container_path"
            linked=$((linked + 1))
            ;;
    esac
done

if [ "$linked" -gt 0 ] || [ "$merged" -gt 0 ] || [ "$warned" -gt 0 ]; then
    echo "share-claude-sessions: $merged dir(s) mergeado(s) + $linked symlink(s) creado(s) + $warned warning(s) en $PROJECTS_DIR."
fi
