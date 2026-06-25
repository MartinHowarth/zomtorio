#!/usr/bin/env bash
# Validate every base/core/space-age/quality graphics path the mod references
# against a REAL Factorio install.
#
# Why this exists: the Linux headless server ships NO graphics assets and never
# loads sprite files, so a wrong/missing icon path passes the headless test suite
# and only blows up when a GUI client tries to load the PNG. This script closes
# that gap by resolving every `__mod__/...png` reference against a full install's
# data dir and reporting any that don't exist.
#
# Usage:  FACTORIO_DATA=/path/to/Factorio/data ./test/check-icons.sh
# Default FACTORIO_DATA points at the Steam (Windows) install via WSL.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DATA="${FACTORIO_DATA:-/mnt/c/Program Files (x86)/Steam/steamapps/common/Factorio/data}"

[[ -d "$DATA" ]] || { echo "ERROR: Factorio data dir not found: $DATA" >&2
  echo "Set FACTORIO_DATA to a full install's data/ directory." >&2; exit 2; }

missing=0
# Collect every __mod__/....png reference from the mod's Lua (not the tests).
while IFS= read -r ref; do
  rel="${ref/__base__/$DATA/base}"
  rel="${rel/__core__/$DATA/core}"
  rel="${rel/__space-age__/$DATA/space-age}"
  rel="${rel/__quality__/$DATA/quality}"
  if [[ -f "$rel" ]]; then
    echo "OK   $ref"
  else
    echo "MISS $ref"
    missing=$((missing + 1))
  fi
done < <(grep -rhoE '__(base|core|space-age|quality)__/[A-Za-z0-9/_.-]+\.png' \
           "$REPO/prototypes" "$REPO"/*.lua 2>/dev/null | sort -u)

echo "----------------------------------------------------------------"
if [[ "$missing" -eq 0 ]]; then
  echo "ALL ICON PATHS OK"; exit 0
else
  echo "$missing MISSING ICON PATH(S) — a GUI client will fail to load the mod."; exit 1
fi
