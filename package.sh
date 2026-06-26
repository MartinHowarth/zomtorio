#!/usr/bin/env bash
# Build the distributable Factorio mod zip (for the mod portal / manual install).
#
# Produces dist/<name>_<version>.zip whose single top-level folder is
# <name>_<version>/ -- the layout the game and the mod portal require. It ships only
# the files the mod needs at runtime; the test suite, the GUI launcher (play.sh),
# this script, the trailer video, working notes (CLAUDE*.md) and the graphics
# generators are all left out.
#
# Uses python3 for the zip step, since `zip` isn't installed everywhere.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

NAME="$(grep -oP '"name"\s*:\s*"\K[^"]+' info.json)"
VERSION="$(grep -oP '"version"\s*:\s*"\K[^"]+' info.json)"
[[ -n "$NAME" && -n "$VERSION" ]] || {
  echo "ERROR: could not read name/version from info.json" >&2; exit 1; }

FOLDER="${NAME}_${VERSION}"
OUT="$HERE/dist"
ZIP="$OUT/${FOLDER}.zip"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/$FOLDER"
mkdir -p "$DEST"

# Stage the shipping files (copy via tar with an exclude list, like play.sh does).
# Everything not needed by the running mod is excluded here. NOTE: tar's exclude
# globs match across '/', so e.g. './graphics/*.gen.py' drops the generators while
# keeping the PNGs they produce.
tar \
  --exclude='./.git' \
  --exclude='./.gitignore' \
  --exclude='./.gitattributes' \
  --exclude='./dist' \
  --exclude='./test' \
  --exclude='./play.sh' \
  --exclude='./package.sh' \
  --exclude='./CLAUDE.md' \
  --exclude='./CLAUDE.local.md' \
  --exclude='./*.mp4' \
  --exclude='./graphics/*.gen.py' \
  --exclude='./graphics/*-old.png' \
  -cf - . | tar -C "$DEST" -xf -

mkdir -p "$OUT"
rm -f "$ZIP"

# Zip the staged folder. arcname keeps the required <name>_<version>/ prefix.
python3 - "$STAGE" "$FOLDER" "$ZIP" <<'PY'
import os, sys, zipfile
stage, folder, zippath = sys.argv[1], sys.argv[2], sys.argv[3]
root = os.path.join(stage, folder)
with zipfile.ZipFile(zippath, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, _dirs, files in os.walk(root):
        for f in sorted(files):
            full = os.path.join(dirpath, f)
            z.write(full, os.path.relpath(full, stage))  # keeps <folder>/ prefix
PY

echo "Built $ZIP"
echo "Contents:"
python3 - "$ZIP" <<'PY'
import sys, zipfile
for n in sorted(zipfile.ZipFile(sys.argv[1]).namelist()):
    print("  " + n)
PY
