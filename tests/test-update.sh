#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Fixture upstream with two tags; clone sitting at old pin
fixture="$TEST_TMP/upstream-remote"
mkdir -p "$fixture/src/apps/cli/deploy"
echo '{}' > "$fixture/src/apps/cli/package.json"
echo '#!/usr/bin/env bash' > "$fixture/src/apps/cli/deploy/install.sh"
git -C "$fixture" init -q && git -C "$fixture" add -A
git -C "$fixture" -c user.email=t@t -c user.name=t commit -qm v1
git -C "$fixture" tag 9.9.8
echo '{"v":2}' > "$fixture/src/apps/cli/package.json"
git -C "$fixture" add -A && git -C "$fixture" -c user.email=t@t -c user.name=t commit -qm v2
git -C "$fixture" tag 9.9.9

clone="$TEST_TMP/upstream-clone"
git -C "$fixture" clone -q "$fixture" "$clone"
git -C "$clone" checkout -q 9.9.8
echo "9.9.8" > "$clone/.livesync-headless-pin"

repo="$TEST_TMP/repo"   # mini repo holding only upstream.pin
mkdir -p "$repo/scripts" "$repo/scripts/lib"
cp "$SCRIPT_DIR/../scripts/lib/config.sh" "$repo/scripts/lib/"
echo "9.9.9" > "$repo/upstream.pin"

run_update() {
    VAULT_DIR="$TEST_TMP/vault" UPSTREAM_DIR="$clone" REPO_DIR="$repo" \
    UPSTREAM_REMOTE="$fixture" SKIP_BUILD=1 SKIP_INSTALL=1 SKIP_VERIFY=1 \
        bash "$SCRIPT_DIR/../scripts/update.sh"
}

# 1. pin unchanged -> abort
echo "9.9.8" > "$repo/upstream.pin"
assert_exit_code 1 run_update
ok "update refuses when pin unchanged"
echo "9.9.9" > "$repo/upstream.pin"

# 2. pin changed -> checkout, record, succeed
assert_exit_code 0 run_update
assert_eq "$(git -C "$clone" describe --tags)" "9.9.9" "clone moved to new pin"
assert_eq "$(cat "$clone/.livesync-headless-pin")" "9.9.9" "new pin recorded"

# 3. Review Focus: read-only marker present, READ_ONLY unset -> abort with guidance
mkdir -p "$TEST_TMP/vault/.livesync"
touch "$TEST_TMP/vault/.livesync/read-only-mode"
echo "9.9.8" > "$repo/upstream.pin"
ro_out="$TEST_TMP/ro-update.out"; rc=0
run_update >"$ro_out" 2>&1 || rc=$?
assert_eq "$rc" "1" "update aborts on read-only marker without READ_ONLY=1"
assert_file_contains "$ro_out" "Read-only install detected" "abort explains the read-only marker"
assert_file_contains "$ro_out" "READ_ONLY=1 make update" "abort tells the operator how to proceed"

# 4. read-only marker present + READ_ONLY=1 -> proceeds normally
rc=0
VAULT_DIR="$TEST_TMP/vault" UPSTREAM_DIR="$clone" REPO_DIR="$repo" \
UPSTREAM_REMOTE="$fixture" SKIP_BUILD=1 SKIP_INSTALL=1 SKIP_VERIFY=1 READ_ONLY=1 \
    bash "$SCRIPT_DIR/../scripts/update.sh" >"$ro_out" 2>&1 || rc=$?
assert_eq "$rc" "0" "update proceeds with READ_ONLY=1 despite marker"
assert_eq "$(git -C "$clone" describe --tags)" "9.9.8" "clone moved to pin under READ_ONLY=1"

finish
