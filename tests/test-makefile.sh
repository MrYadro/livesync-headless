#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

makefile="$SCRIPT_DIR/../Makefile"

# 1. all targets exist
for t in bootstrap install update status verify test test-e2e-local pull-once readonly-on readonly-off import-uri; do
    assert_file_contains "$makefile" "$t:" "Makefile has target: $t"
done

# 2. .PHONY line present (so targets always run)
assert_file_contains "$makefile" ".PHONY:" "Makefile marks targets phony"

# 3. targets forward to scripts (spot-checks)
assert_file_contains "$makefile" "scripts/bootstrap.sh" "bootstrap target runs script"
assert_file_contains "$makefile" "scripts/verify.sh" "verify target runs script"
assert_file_contains "$makefile" "scripts/pull-once.sh" "pull-once target runs script"
assert_file_contains "$makefile" "scripts/couchdb-readonly.sh on" "readonly-on runs guard script"
assert_file_contains "$makefile" "scripts/import-uri.sh" "import-uri target runs script"

finish
