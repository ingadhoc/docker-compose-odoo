# Formatter

We use the ruff formatter and each repository ins configuring using the `pyproject.toml` file. And in the root  of respository folder there is the same file in case of is not configured on your repo.

## How to

Disable the autoformatter on save

.devcotainer/.vscode/settings.json

```json
{
    "[python]": {
            "editor.formatOnSave": false
    }
}
```
