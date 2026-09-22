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

finish
