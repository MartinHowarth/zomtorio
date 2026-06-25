#!/usr/bin/env bash
# Headless Zomtorio test runner.
#
# Spins up the Linux headless engine in an ISOLATED data dir (so the user's
# heavily-modded Factorio profile is never touched), loads the zomtorio-tests
# harness mod, runs all specs, captures results, and exits non-zero on failure.
#
# We use --benchmark (not --start-server): a multiplayer server does not advance
# ticks until a player connects, whereas --benchmark ticks the map at max speed,
# runs mod scripts, and exits on its own. The harness runs its tests during those
# ticks and writes script-output/test-results.json.
#
# Env overrides:
#   FACTORIO_SERVER   path to extracted headless install (dir with bin/, data/)
#   ENABLE_SPACE_AGE  set to 1 to enable Space Age DLC mods (default: base only)
#   BENCH_TICKS       ticks to run (default: 30000; must exceed total test waits)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SERVER="${FACTORIO_SERVER:-$HOME/factorio-headless/factorio}"
BIN="$SERVER/bin/x64/factorio"
BENCH_TICKS="${BENCH_TICKS:-30000}"

[[ -x "$BIN" ]] || { echo "ERROR: factorio binary not found at $BIN" >&2; exit 2; }

# Isolated, gitignored data dir.
TDATA="$HERE/.factorio-data"
MODS="$TDATA/mods"
OUT="$TDATA/script-output"
SAVE="$TDATA/test-map.zip"
RESULTS="$OUT/test-results.json"
LOG="$TDATA/server.log"
rm -rf "$TDATA"
mkdir -p "$MODS" "$OUT"

# Optional single-test filter: TEST_FILTER=<name substring> runs only the tests
# whose name contains that substring (the harness reads the generated _filter.lua;
# absent => run everything). Written into the harness mod dir so require() finds it.
FILTER_FILE="$HERE/zomtorio-tests/_filter.lua"
if [[ -n "${TEST_FILTER:-}" ]]; then
  printf 'return [[%s]]\n' "$TEST_FILTER" > "$FILTER_FILE"
  echo ">> filtering to tests matching: \"$TEST_FILTER\""
else
  rm -f "$FILTER_FILE"
fi

# Link the harness mod (unzipped folder named exactly its mod name).
ln -sfn "$HERE/zomtorio-tests" "$MODS/zomtorio-tests"
# Link the main mod too, but only once it's a valid 2.1 mod (so the harness can
# load standalone today and pick up zomtorio automatically once it exists).
if grep -q '"factorio_version"[[:space:]]*:[[:space:]]*"2\.' "$REPO/info.json" 2>/dev/null; then
  ln -sfn "$REPO" "$MODS/zomtorio"
  ZOMTORIO_LINE=',{"name":"zomtorio","enabled":true}'
else
  ZOMTORIO_LINE=''
fi

# Config: point read-data at the install, write-data at our isolated dir.
cat > "$TDATA/config.ini" <<EOF
[path]
read-data=$SERVER/data
write-data=$TDATA
EOF

# Mod list: base + harness (+ zomtorio if present). Space Age ON by default — the mod
# requires it (spoilage/quality feature flags). Set ENABLE_SPACE_AGE=0 to force base-only.
SA="true"; [[ "${ENABLE_SPACE_AGE:-1}" == "1" ]] || SA="false"
cat > "$MODS/mod-list.json" <<EOF
{"mods":[
  {"name":"base","enabled":true},
  {"name":"elevated-rails","enabled":$SA},
  {"name":"quality","enabled":$SA},
  {"name":"recycler","enabled":$SA},
  {"name":"space-age","enabled":$SA},
  {"name":"zomtorio-tests","enabled":true}$ZOMTORIO_LINE
]}
EOF

echo ">> creating test map (no natural enemy bases)..."
"$BIN" --config "$TDATA/config.ini" --mod-directory "$MODS" \
       --map-gen-settings "$HERE/map-gen-no-enemies.json" \
       --create "$SAVE" >"$LOG" 2>&1 || { echo "map creation failed:"; cat "$LOG"; exit 2; }

echo ">> running tests via benchmark (ticks=$BENCH_TICKS)..."
"$BIN" --config "$TDATA/config.ini" --mod-directory "$MODS" \
       --benchmark "$SAVE" --benchmark-ticks "$BENCH_TICKS" --benchmark-runs 1 \
       --benchmark-ignore-paused >>"$LOG" 2>&1 || true

if [[ ! -f "$RESULTS" ]]; then
  echo "ERROR: no results produced. Server log tail:" >&2
  grep -iE 'error|fail|exception|zomtorio' "$LOG" | tail -30 >&2 || tail -30 "$LOG" >&2
  exit 1
fi

echo "----------------------------------------------------------------"
grep -E 'ZOMTORIO-TESTS' "$LOG" || true
echo "----------------------------------------------------------------"
cat "$RESULTS"; echo

if grep -q '"failed":0,' "$RESULTS"; then
  echo "ALL TESTS PASSED"; exit 0
else
  echo "TEST FAILURES"; exit 1
fi
