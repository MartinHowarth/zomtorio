#!/usr/bin/env bash
# Launch the Steam (Windows) Factorio GUI client with ONLY the zomtorio mod loaded
# (plus its hard dependency, Space Age) — no test harness, just the shipping mod, so
# you can actually play it.
#
# Like the test launchers it uses an ISOLATED mod profile on the Windows filesystem,
# so your ~60 installed mods don't interfere. UNLIKE the test launchers it does NOT
# wipe the profile each run — your saves persist in this profile between launches; we
# only refresh the zomtorio mod copy so code changes are picked up. It launches to the
# main menu so you can start a new game (normal enemies) or load a previous one.
#
# Prereqs: Steam should be running (the Steam build may require it to launch).
#
# Env overrides:
#   FACTORIO_EXE      path to factorio.exe (default: Steam common path)
#   ENABLE_SPACE_AGE  default 1 (the mod requires Space Age)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # repo root (the mod folder)
EXE="${FACTORIO_EXE:-/mnt/c/Program Files (x86)/Steam/steamapps/common/Factorio/bin/x64/factorio.exe}"
[[ -f "$EXE" ]] || { echo "ERROR: factorio.exe not found at: $EXE" >&2; exit 2; }

INSTALL="$(cd "$(dirname "$EXE")/../.." && pwd)"   # .../common/Factorio
SA="true"; [[ "${ENABLE_SPACE_AGE:-1}" == "1" ]] || SA="false"

# Persistent, isolated Windows-side profile (symlinks don't work on /mnt/c, so we copy
# the mod in). Distinct from the test profile (zomtorio-test) so saves never mix.
PROFILE_WIN="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
WORK="$(wslpath -u "$PROFILE_WIN")/zomtorio-play"
MODS="$WORK/mods"
mkdir -p "$MODS"

# Refresh ONLY the mod copy (keep saves/config). Exclude repo cruft + the test dir, so
# the test harness mod is never present.
rm -rf "$MODS/Zomtorio"
mkdir -p "$MODS/Zomtorio"
(cd "$HERE" && tar --exclude='./.git' --exclude='./test' --exclude='./.factorio-data' \
    --exclude='./play.sh' -cf - .) | (cd "$MODS/Zomtorio" && tar -xf -)

cat > "$MODS/mod-list.json" <<EOF
{"mods":[
  {"name":"base","enabled":true},
  {"name":"elevated-rails","enabled":$SA},
  {"name":"quality","enabled":$SA},
  {"name":"space-age","enabled":$SA},
  {"name":"Zomtorio","enabled":true}
]}
EOF

# Seed a FULL, valid config.ini from your real Factorio config — a sparse [path]-only
# config is tolerated by headless/map-create but the interactive GUI flags it as
# "invalid contents". We override only the data paths so this profile stays isolated
# (its own saves/mods/mod-settings under $WORK). Seed only if absent, so any in-game
# settings you change in this profile persist across launches. Delete it to regenerate.
# Reseed when the config is missing OR is the old sparse stub (no [general] section) —
# a full config left in place by a normal launch is kept so your in-game settings persist.
CFG="$WORK/config.ini"
if [[ ! -f "$CFG" ]] || ! grep -q '^\[general\]' "$CFG"; then
  RD="$(wslpath -w "$INSTALL/data" | tr '\\' '/')"   # forward slashes: Factorio accepts
  WD="$(wslpath -w "$WORK" | tr '\\' '/')"           # them and they keep sed simple
  REAL_CONFIG="$(wslpath -u "$(cmd.exe /c 'echo %APPDATA%' 2>/dev/null | tr -d '\r')")/Factorio/config/config.ini"
  if [[ -f "$REAL_CONFIG" ]]; then
    sed -E "s#^read-data=.*#read-data=$RD#; s#^write-data=.*#write-data=$WD#" \
      "$REAL_CONFIG" > "$CFG"
    echo ">> seeded config from your Factorio config (data paths isolated to this profile)"
  else
    printf '[path]\nread-data=%s\nwrite-data=%s\n' "$RD" "$WD" > "$CFG"
    echo ">> no system config found; wrote a minimal config.ini"
  fi
fi

CFG_WIN="$(wslpath -w "$CFG")"
MODS_WIN="$(wslpath -w "$MODS")"

echo ">> profile: $WORK"
echo ">> mods: base + Space Age (SA=$SA) + zomtorio (no test harness)"
echo ">> launching GUI to the menu — start a new game or load a save. Close the window when done."
"$EXE" --config "$CFG_WIN" --mod-directory "$MODS_WIN" &
echo ">> launched (pid $!). If nothing appears, make sure Steam is running."
