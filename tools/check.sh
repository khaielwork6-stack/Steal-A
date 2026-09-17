#!/usr/bin/env bash
# Static check: syntax + type analysis with Roblox definitions.
# Usage: tools/check.sh [file-or-dir ...]   (default: src)
# Prints SyntaxErrors and "Unknown global"/"Unknown require" errors (always bugs),
# then a per-file TypeError count so a change can be compared with the baseline.
# Exit status: 1 when the "hard errors" section is non-empty (or a tool is
# missing), 0 otherwise. TypeErrors never fail the check.
# Tools: rojo and luau-lsp from Rokit (~/.rokit/bin) or anywhere on PATH.
set -u
cd "$(dirname "$0")/.."
if [ -d "$HOME/.rokit/bin" ]; then
  export PATH="$HOME/.rokit/bin:$PATH"
fi
for tool in rojo luau-lsp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "tools/check.sh: '$tool' not found (install with: rokit install)" >&2
    exit 1
  fi
done
if [ ! -s .luau-types/globalTypes.d.luau ]; then
  mkdir -p .luau-types
  if ! curl -fsSL -o .luau-types/globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.None.d.luau; then
    rm -f .luau-types/globalTypes.d.luau
    echo "tools/check.sh: could not download the Roblox type definitions" >&2
    exit 1
  fi
fi
if ! rojo sourcemap default.project.json -o sourcemap.json >/dev/null; then
  echo "tools/check.sh: rojo sourcemap failed" >&2
  exit 1
fi
out=$(luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json --definitions=.luau-types/globalTypes.d.luau "${@:-src}" 2>&1)
# Backups: the retired client backup folder is excluded if it ever comes back.
hard=$(echo "$out" | grep -E "SyntaxError|Unknown global|Unknown require" | grep -v "Backups" | sort -u || true)
echo "== hard errors (must be zero) =="
if [ -n "$hard" ]; then
  echo "$hard"
fi
echo "== TypeErrors per file =="
echo "$out" | grep -oE "src[\/][^ ]+\.luau" | sort | uniq -c | sort -rn
if [ -n "$hard" ]; then
  echo "== FAILED: $(echo "$hard" | wc -l | tr -d ' ') hard error(s) ==" >&2
  exit 1
fi
exit 0
