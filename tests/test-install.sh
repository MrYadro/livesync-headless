#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Fixture upstream (clone from Task-3-style fixture) with stub installer that logs its args
fixture="$TEST_TMP/upstream-remote"
mkdir -p "$fixture/src/apps/cli/deploy"
echo '{}' > "$fixture/src/apps/cli/package.json"
cat > "$fixture/src/apps/cli/deploy/install.sh" <<'EOS'
#!/usr/bin/env bash
echo "INSTALLER_ARGS: $*" >> "$INSTALL_LOG"
EOS
chmod +x "$fixture/src/apps/cli/deploy/install.sh"
git -C "$fixture" init -q && git -C "$fixture" add -A
git -C "$fixture" -c user.email=t@t -c user.name=t commit -qm fixture
git -C "$fixture" tag 9.9.9

clone="$TEST_TMP/upstream-clone"
git -C "$fixture" clone -q "$fixture" "$clone"

vault="$TEST_TMP/vault"
cli_log="$TEST_TMP/cli.log"
export INSTALL_LOG="$TEST_TMP/installer.log"
: > "$INSTALL_LOG"

run_install() {
    VAULT_DIR="$vault" UPSTREAM_DIR="$clone" REPO_DIR="$SCRIPT_DIR/.." \
    COUCHDB_URI="http://127.0.0.1:15984" COUCHDB_DBNAME="testdb" \
    COUCHDB_USER="admin" COUCHDB_PASSWORD="install-test-password" \
    E2E_PASSPHRASE="e" OBFUSCATE_PASSPHRASE="o" \
    SKIP_BOOTSTRAP=1 LIVESYNC_CLI_CMD="bash $TEST_TMP/stub-cli.sh" \
        bash "$SCRIPT_DIR/../scripts/install.sh"
}

cat > "$TEST_TMP/stub-cli.sh" <<'EOS'
#!/usr/bin/env bash
echo "cli: $*" >> "${CLI_LOG:?}"
exit "${CLI_EXIT:-0}"
EOS

# 1. happy path: settings created, preflight ran, installer invoked with --vault
export CLI_LOG="$cli_log"
run_install
[[ -f "$vault/.livesync/settings.json" ]] && ok "settings created" || fail "settings created"
assert_file_contains "$cli_log" "sync" "preflight sync executed"
assert_file_contains "$INSTALL_LOG" "--user --vault $vault" "installer called with --user --vault"
T="$vault/.livesync/settings.json" assert_exit_code 0 node -e '
    const s = JSON.parse(require("fs").readFileSync(process.env.T, "utf8"));
    process.exit(s.isConfigured === true ? 0 : 1);
' && ok "isConfigured set to true"

# 2. installer NOT called again when settings already exist (idempotent config step)
before=$(grep -c INSTALLER_ARGS "$INSTALL_LOG" || true)
run_install
after=$(grep -c INSTALLER_ARGS "$INSTALL_LOG" || true)
assert_eq "$after" "$((before + 1))" "installer ran exactly once more"
[[ "$(grep -c 'cli: .* sync' "$cli_log")" -ge 2 ]] && ok "preflight re-runs each install"

# 3. Review Focus: preflight sync failure aborts before installer
#    (rc captured with || so `set -e` does not kill the test)
: > "$INSTALL_LOG"
rc=0
CLI_EXIT=1 run_install || rc=$?
assert_eq "$rc" "1" "install exits non-zero on preflight failure"
if [[ -s "$INSTALL_LOG" ]]; then fail "installer must not run after failed preflight"; else ok "installer skipped after failed preflight"; fi

# 4. missing secrets in non-interactive mode -> abort with clear error
rm -rf "$vault/.livesync"
out=$(VAULT_DIR="$vault" UPSTREAM_DIR="$clone" REPO_DIR="$SCRIPT_DIR/.." \
    SKIP_BOOTSTRAP=1 LIVESYNC_CLI_CMD="bash $TEST_TMP/stub-cli.sh" \
    bash "$SCRIPT_DIR/../scripts/install.sh" </dev/null 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "aborts without secrets in non-tty mode"
assert_file_contains <(echo "$out") "COUCHDB_USER" "error names the first missing variable"

# 5. Review Focus: READ_ONLY=1 never runs sync or the upstream installer
vault_ro="$TEST_TMP/vault-ro"
units="$TEST_TMP/units"; mkdir -p "$units"
cat > "$TEST_TMP/curl.sh" <<'EOS'
#!/usr/bin/env bash
echo "curl: $*" >> "${CURL_LOG:?}"
exit 0
EOS
cat > "$TEST_TMP/systemctl-ro.sh" <<'EOS'
#!/usr/bin/env bash
echo "systemctl: $*" >> "${SYSTEMCTL_LOG:?}"
exit 0
EOS
chmod +x "$TEST_TMP/curl.sh" "$TEST_TMP/systemctl-ro.sh"
export CURL_LOG="$TEST_TMP/curl.log" SYSTEMCTL_LOG="$TEST_TMP/systemctl.log"
: > "$CURL_LOG"; : > "$SYSTEMCTL_LOG"; : > "$INSTALL_LOG"; : > "$cli_log"

rc=0
VAULT_DIR="$vault_ro" UPSTREAM_DIR="$clone" REPO_DIR="$SCRIPT_DIR/.." \
SKIP_BOOTSTRAP=1 READ_ONLY=1 \
COUCHDB_URI="http://127.0.0.1:15984" COUCHDB_DBNAME="testdb" \
COUCHDB_USER="reader" COUCHDB_PASSWORD="readerpass" \
E2E_PASSPHRASE="e" OBFUSCATE_PASSPHRASE="o" \
LIVESYNC_CLI_CMD="bash $TEST_TMP/stub-cli.sh" \
CURL_CMD="bash $TEST_TMP/curl.sh" \
SYSTEMCTL_CMD="bash $TEST_TMP/systemctl-ro.sh" \
UNIT_DIR="$units" \
    bash "$SCRIPT_DIR/../scripts/install.sh" || rc=$?
assert_eq "$rc" "0" "read-only install succeeds"
if [[ -s "$cli_log" ]]; then fail "read-only install must not run sync"; else ok "read-only install never calls the CLI"; fi
if [[ -s "$INSTALL_LOG" ]]; then fail "read-only install must not run upstream installer"; else ok "upstream installer skipped in read-only mode"; fi
assert_file_contains "$CURL_LOG" "127.0.0.1:15984/testdb" "read-only preflight GETs the database URL"
assert_file_contains "$units/livesync-readonly.service" "readonly-loop.sh" "unit runs readonly-loop.sh"
assert_file_contains "$units/livesync-readonly.service" "$vault_ro" "unit points at the vault"
assert_file_contains "$SYSTEMCTL_LOG" "enable --now livesync-readonly.service" "service enabled"

finish
