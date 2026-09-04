#!/bin/bash

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

bash -n "$ROOT/../bin/notification-center" "$ROOT/seen-race-test.sh" "$ROOT/focus-argv-test.sh"
"$ROOT/seen-race-test.sh"
"$ROOT/focus-argv-test.sh"
