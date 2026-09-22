#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Local "upstream" fixture repo with tag 9.9.9 and the files bootstrap checks
fixture="$TEST_TMP/upstream-remote"
mkdir -p "$fixture/src/apps/cli/deploy"
echo '{"name":"self-hosted-livesync-cli"}' > "$fixture/src/apps/cli/package.json"
echo '#!/usr/bin/env bash' > "$fixture/src/apps/cli/deploy/install.sh"
git -C "$fixture" init -q
git -C "$fixture" add -A
git -C "$fixture" -c user.email=t@t -c user.name=t commit -qm "fixture"
git -C "$fixture" tag 9.9.9

clone="$TEST_TMP/upstream-clone"

run_bootstrap() {
    UPSTREAM_REMOTE="$fixture" UPSTREAM_DIR="$clone" SKIP_BUILD=1 \
        REPO_DIR="$SCRIPT_DIR/.." PIN_OVERRIDE=9.9.9 \
        bash "$SCRIPT_DIR/../scripts/bootstrap.sh"
}

# 1. clones at pin and records it
run_bootstrap
assert_eq "$(git -C "$clone" describe --tags)" "9.9.9" "clone checked out at pinned tag"
assert_eq "$(cat "$clone/.livesync-headless-pin")" "9.9.9" "pin recorded"

# 2. idempotent second run
run_bootstrap
ok "second bootstrap succeeds"

# 3. Review Focus: refuses dirty upstream tree (modify a TRACKED file;
#    untracked files are tolerated because the pin record is untracked)
echo "local junk" >> "$clone/src/apps/cli/package.json"
assert_exit_code 1 run_bootstrap
ok "bootstrap refuses dirty clone"

finish
