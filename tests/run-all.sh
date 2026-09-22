#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$SCRIPT_DIR"/test-*.sh; do
    echo "== $(basename "$t")"
    bash "$t" || rc=1
done
exit "$rc"
