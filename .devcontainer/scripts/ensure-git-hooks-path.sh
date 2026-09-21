#!/bin/bash
#
# core.hooksPath del host no sobrevive al container.
#
# VS Code copia el ~/.gitconfig del host al crear el container. En las máquinas
# del equipo el rol `developer` de ansible apunta core.hooksPath a
# /home/<usuario-del-host>/.git_hooks, path que acá adentro no existe. Con un
# hooksPath que no resuelve git no corre NINGUN hook, en ningún repo del
# workspace: ni los que instala pre-commit ni el guardrail de push directo a la
# productiva. Y `pre-commit install` se niega mientras esté seteado ("Cowardly
# refusing to install hooks with core.hooksPath set"), con un error que no
# nombra la causa.
#
# Aditivo e idempotente: solo desarma el valor cuando el directorio no existe.
# Corre en cada arranque (postStart) para que los containers ya creados lo
# reciban sin rebuild, y desde el poststart para cubrir el primer arranque.

hooks_path="$(git config --global --get core.hooksPath 2>/dev/null)" || exit 0
[ -n "$hooks_path" ] || exit 0

if [ -d "$hooks_path" ]; then
    echo "git: core.hooksPath ($hooks_path) existe acá adentro; lo dejo como está."
    exit 0
fi

git config --global --unset-all core.hooksPath
echo "git: core.hooksPath apuntaba a $hooks_path (path del host); lo saqué para que corran los hooks del repo."
