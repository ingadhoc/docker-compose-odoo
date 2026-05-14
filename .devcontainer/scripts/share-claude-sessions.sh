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
            if [ "$host_name" != "$container_name" ] && [ ! -e "$PROJECTS_DIR/$container_name" ]; then
                # `--` separa flags del target — `$host_name` empieza con `-`
                # (es un dir encoded), si no, ln lo trata como opción y falla
                # con `invalid option -- 'h'`.
                ln -s -- "$host_name" "$PROJECTS_DIR/$container_name"
                linked=$((linked + 1))
            fi
            ;;
    esac
done

if [ "$linked" -gt 0 ]; then
    echo "share-claude-sessions: $linked symlink(s) nuevo(s) en $PROJECTS_DIR."
fi
