#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p -- "$TMP/plugin/tests/bin"
cp -- "$ROOT/Service.qml" "$TMP/plugin/tests/Service.qml"
cp -- "$ROOT/tests/SeenRace.qml" "$TMP/plugin/tests/SeenRace.qml"

LOG="$TMP/seen.log"
cat > "$TMP/plugin/tests/bin/notification-center" <<'SCRIPT'
#!/bin/bash
case ${1:-} in
  watch) sleep 2 ;;
  list) printf '[]\n' ;;
  seen)
    if [[ $# -eq 1 ]]; then
      printf '{"ok":true,"seen":0}\n'
    else
      sleep 0.2
      printf '%s\n' "$2" >> "$NC_TEST_LOG"
      printf '{"ok":true,"seen":%s}\n' "$2"
    fi
    ;;
esac
SCRIPT
chmod +x "$TMP/plugin/tests/bin/notification-center"

if ! NC_TEST_LOG="$LOG" QT_QPA_PLATFORM=offscreen \
  quickshell --no-color -p "$TMP/plugin/tests/SeenRace.qml" >"$TMP/quickshell.log" 2>&1; then
  printf 'FAIL: quickshell harness did not load\n' >&2
  while IFS= read -r line; do printf '%s\n' "$line" >&2; done < "$TMP/quickshell.log"
  exit 1
fi

count=$(wc -l < "$LOG")
if [[ $count -ne 2 ]]; then
  printf 'FAIL: expected both rapid seen timestamps to persist, got %s write(s)\n' "$count" >&2
  exit 1
fi

mapfile -t stamps < "$LOG"
first=${stamps[0]}
second=${stamps[1]}
if (( second < first )); then
  printf 'FAIL: seen timestamps moved backwards: %s then %s\n' "$first" "$second" >&2
  exit 1
fi

printf 'seen-race-test: ok\n'
