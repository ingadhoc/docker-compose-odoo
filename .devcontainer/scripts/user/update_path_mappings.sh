#!/bin/bash

set -euo pipefail

LAUNCH_JSON="/home/odoo/custom/repositories/.vscode/launch.json"
WORKSPACE="/home/odoo/custom/repositories"
ADDONS_BASE="/home/odoo/src/odoo/odoo/addons"
TMP_JSON=$(mktemp)

if ! grep -q '"pathMappings"[[:space:]]*:[[:space:]]*\[' "$LAUNCH_JSON"; then
    exit 0
fi

inside=0
while IFS= read -r line; do
    if [[ $line =~ \"pathMappings\"[[:space:]]*:[[:space:]]*\[ ]]; then
        echo "$line" >> "$TMP_JSON"
        inside=1
        FIRST=1
        for repo in "$WORKSPACE"/*; do
            parent=$(basename "$repo")
            [[ ! -d "$repo" || "$parent" == .* || "$parent" == src* ]] && continue
            for module in "$repo"/*; do
                [ -d "$module" ] || continue
                [ -f "$module/__manifest__.py" ] || continue
                modname=$(basename "$module")
                [[ $FIRST -eq 0 ]] && echo "," >> "$TMP_JSON"
                FIRST=0
                echo "                {" >> "$TMP_JSON"
                echo "                    \"localRoot\": \"\${workspaceFolder}/$parent/$modname\"," >> "$TMP_JSON"
                echo "                    \"remoteRoot\": \"$ADDONS_BASE/$modname\"" >> "$TMP_JSON"
                echo -n "                }" >> "$TMP_JSON"
            done
        done
        echo "" >> "$TMP_JSON"
        continue
    fi

    if [[ $inside -eq 1 && $line =~ \] ]]; then
        echo "            ]," >> "$TMP_JSON"
        inside=0
        continue
    fi

    if [[ $inside -eq 1 ]]; then
        continue
    fi

    echo "$line" >> "$TMP_JSON"
done < "$LAUNCH_JSON"

mv "$TMP_JSON" "$LAUNCH_JSON"
