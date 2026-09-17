#!/usr/bin/env bash
# Static check: syntax + type analysis with Roblox definitions.
# Usage: tools/check.sh [file-or-dir ...]   (default: src)
# Prints SyntaxErrors and "Unknown global"/"Unknown require" errors (always bugs),
# then a per-file TypeError count so a change can be compared with the baseline.
set -u
cd "$(dirname "$0")/.."
export PATH="$HOME/.rokit/bin:$PATH"
if [ ! -f .luau-types/globalTypes.d.luau ]; then
  mkdir -p .luau-types
  curl -sSL -o .luau-types/globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.None.d.luau
fi
rojo sourcemap default.project.json -o sourcemap.json >/dev/null
out=$(luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json --definitions=.luau-types/globalTypes.d.luau "${@:-src}" 2>&1)
echo "== hard errors (must be zero) =="
echo "$out" | grep -E "SyntaxError|Unknown global|Unknown require" | grep -v "Backups" | sort -u || true
echo "== TypeErrors per file =="
echo "$out" | grep -oE "src[\/][^ ]+\.luau" | sort | uniq -c | sort -rn
