#!/bin/bash
# Puts the host's ~/.claude.json in place: it is not bound directly because Claude
# replaces it by rename, which strands a file bind. Keeps this container's own
# `projects` entries (folder trust) across restarts; the host wins on shared keys.
set -euo pipefail

src="$HOME/.claude.host.json"
dst="$HOME/.claude.json"
[ -f "$src" ] || exit 0

if [ -f "$dst" ] && jq -e . "$dst" >/dev/null 2>&1; then
    tmp="$(mktemp "$dst.XXXXXX")"
    jq -s '.[0] * {projects: ((.[1].projects // {}) + (.[0].projects // {}))}' "$src" "$dst" > "$tmp"
    mv -f "$tmp" "$dst"
else
    cp -f "$src" "$dst"
fi
