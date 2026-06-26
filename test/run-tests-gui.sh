#!/usr/bin/env bash
# Launch the test scenarios in the GUI client so you can WATCH them run.
#
# Uses your Steam Factorio (Windows) via WSL interop, but in an ISOLATED mod
# profile on the Windows filesystem so your ~60 installed mods don't interfere.
# The harness auto-detects the connected player and runs at normal speed,
# teleporting the camera to each test setup and printing pass/fail on screen.
#
# Prereqks: Steam should be running (the Steam build may require it to launch).
#
# Env overrides:
#   FACTORIO_EXE   path to factorio.exe (default: Steam common path)
#   ENABLE_SPACE_AGE  default 1 here (the mod requires Space Age)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
EXE="${FACTORIO_EXE:-/mnt/c/Program Files (x86)/Steam/steamapps/common/Factorio/bin/x64/factorio.exe}"
[[ -f "$EXE" ]] || { echo "ERROR: factorio.exe not found at: $EXE" >&2; exit 2; }

INSTALL="$(cd "$(dirname "$EXE")/../.." && pwd)"   # .../common/Factorio
SA="true"; [[ "${ENABLE_SPACE_AGE:-1}" == "1" ]] || SA="false"

# Isolated Windows-side working dir (symlinks don't work on /mnt/c, so we copy).
PROFILE_WIN="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
WORK="$(wslpath -u "$PROFILE_WIN")/zomtorio-test"
MODS="$WORK/mods"
SAVE="$WORK/test-map.zip"
rm -rf "$WORK"; mkdir -p "$MODS"

cp -r "$HERE/zomtorio-tests" "$MODS/zomtorio-tests"

# Optional single-test filter (same as headless): TEST_FILTER=<name substring>
# runs only matching tests. Write/remove _filter.lua in the COPIED harness dir
# (also clears any stale copy carried over from a headless run).
FILTER_FILE="$MODS/zomtorio-tests/_filter.lua"
if [[ -n "${TEST_FILTER:-}" ]]; then
  printf 'return [[%s]]\n' "$TEST_FILTER" > "$FILTER_FILE"
  echo ">> filtering to tests matching: \"$TEST_FILTER\""
else
  rm -f "$FILTER_FILE"
fi

ZOMTORIO_LINE=''
if grep -q '"factorio_version"[[:space:]]*:[[:space:]]*"2\.' "$REPO/info.json" 2>/dev/null; then
  # copy the main mod, excluding repo cruft
  mkdir -p "$MODS/Zomtorio"
  (cd "$REPO" && tar --exclude='./.git' --exclude='./test' --exclude='./.factorio-data' \
      -cf - .) | (cd "$MODS/Zomtorio" && tar -xf -)
  ZOMTORIO_LINE=',{"name":"Zomtorio","enabled":true}'
fi

cat > "$MODS/mod-list.json" <<EOF
{"mods":[
  {"name":"base","enabled":true},
  {"name":"elevated-rails","enabled":$SA},
  {"name":"quality","enabled":$SA},
  {"name":"space-age","enabled":$SA},
  {"name":"zomtorio-tests","enabled":true}$ZOMTORIO_LINE
]}
EOF

# Copy the no-natural-enemies map-gen settings to the Windows-side work dir (the
# Windows client can't read the WSL repo path).
cp "$HERE/map-gen-no-enemies.json" "$WORK/map-gen-no-enemies.json"

cat > "$WORK/config.ini" <<EOF
[path]
read-data=$(wslpath -w "$INSTALL/data")
write-data=$(wslpath -w "$WORK")
EOF

CFG_WIN="$(wslpath -w "$WORK/config.ini")"
MODS_WIN="$(wslpath -w "$MODS")"
SAVE_WIN="$(wslpath -w "$SAVE")"
MAPGEN_WIN="$(wslpath -w "$WORK/map-gen-no-enemies.json")"

echo ">> creating test map (Windows client; no natural enemy bases)..."
"$EXE" --config "$CFG_WIN" --mod-directory "$MODS_WIN" \
       --map-gen-settings "$MAPGEN_WIN" --create "$SAVE_WIN" 2>&1 | tail -3

echo ">> launching GUI (watch the window; camera follows each test)..."
echo "   Close the Factorio window when done."
"$EXE" --config "$CFG_WIN" --mod-directory "$MODS_WIN" --load-game "$SAVE_WIN" &
echo ">> launched (pid $!). If nothing appears, make sure Steam is running."
