#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/../scripts/lib/config.sh"
source "$SCRIPT_DIR/../scripts/lib/settings.sh"

vault="$TEST_TMP/vault"
mkdir -p "$vault/headless-vault-livesync-v2"
COUCHDB_USER=u COUCHDB_PASSWORD=p E2E_PASSPHRASE=e OBFUSCATE_PASSPHRASE=o \
    create_settings "$vault/.livesync/settings.json"

stub_dir="$TEST_TMP/stubs"
mkdir -p "$stub_dir"

run_verify() {
    VAULT_DIR="$vault" REPO_DIR="$SCRIPT_DIR/.." \
    SYSTEMCTL_CMD="bash $stub_dir/systemctl.sh" \
    JOURNALCTL_CMD="bash $stub_dir/journalctl.sh" \
        bash "$SCRIPT_DIR/../scripts/verify.sh"
}

# systemctl stub: active unless SERVICE_INACTIVE=1; expects ${EXPECT_SERVICE:-livesync-cli}
cat > "$stub_dir/systemctl.sh" <<'EOS'
#!/usr/bin/env bash
[[ "${SERVICE_INACTIVE:-0}" == "1" ]] && exit 1
[[ "$1 $2" == "is-active ${EXPECT_SERVICE:-livesync-cli}" ]] || { echo "unexpected systemctl args: $*" >&2; exit 2; }
exit 0
EOS
# journal stub: always shows the daemon reaching live state; adds an error line
# when JOURNAL_ERRORS=1; emits NO live-state lines when JOURNAL_NOT_LIVE=1
cat > "$stub_dir/journalctl.sh" <<'EOS'
#!/usr/bin/env bash
if [[ "${JOURNAL_NOT_LIVE:-0}" != "1" ]]; then
    echo "Sep 23 10:00:00 host livesync-cli[1]: [Daemon] LiveSync active"
fi
if [[ "${JOURNAL_ERRORS:-0}" == "1" ]]; then
    echo "Sep 23 10:00:01 host livesync-cli[1]: some error happened"
fi
exit 0
EOS
chmod +x "$stub_dir"/*.sh

# 1. all healthy -> exit 0
assert_exit_code 0 run_verify
ok "verify passes when healthy"

# 2. service inactive -> non-zero
export SERVICE_INACTIVE=1
rc=0; run_verify || rc=$?
assert_eq "$rc" "1" "verify fails when service inactive"
unset SERVICE_INACTIVE

# 3. Review Focus: obfuscation off -> non-zero
sed -i.bak 's/"usePathObfuscation": true/"usePathObfuscation": false/' "$vault/.livesync/settings.json"
assert_exit_code 1 run_verify
ok "verify fails when obfuscation off"
sed -i.bak 's/"usePathObfuscation": false/"usePathObfuscation": true/' "$vault/.livesync/settings.json"

# 4. local DB directory missing -> non-zero (daemon-safe check replaces ls)
mv "$vault/headless-vault-livesync-v2" "$TEST_TMP/runtime-away"
assert_exit_code 1 run_verify
ok "verify fails when local database directory missing"
mv "$TEST_TMP/runtime-away" "$vault/headless-vault-livesync-v2"

# 5. no live-state journal lines -> non-zero
export JOURNAL_NOT_LIVE=1
rc=0; run_verify || rc=$?
assert_eq "$rc" "1" "verify fails without live-state journal lines"
unset JOURNAL_NOT_LIVE

# 6. journal errors -> warning only, still exit 0
export JOURNAL_ERRORS=1
assert_exit_code 0 run_verify
ok "journal errors are warn-only"
unset JOURNAL_ERRORS

# 7. ALLOW_PLAINTEXT=1 downgrades encrypt check
sed -i.bak 's/"encrypt": true/"encrypt": false/' "$vault/.livesync/settings.json"
assert_exit_code 1 run_verify
ok "encrypt off fails by default"
export ALLOW_PLAINTEXT=1
assert_exit_code 0 run_verify
ok "encrypt off passes with ALLOW_PLAINTEXT=1"
unset ALLOW_PLAINTEXT
sed -i.bak 's/"encrypt": false/"encrypt": true/' "$vault/.livesync/settings.json"

# 8. Review Focus: read-only mode -> checks livesync-readonly.service and
#    skips the journal liveness check (loop logs go to the other unit)
ro_out="$TEST_TMP/ro-verify.out"
touch "$vault/.livesync/read-only-mode"
rc=0
EXPECT_SERVICE=livesync-readonly.service \
JOURNAL_NOT_LIVE=1 \
VAULT_DIR="$vault" REPO_DIR="$SCRIPT_DIR/.." \
SYSTEMCTL_CMD="bash $stub_dir/systemctl.sh" \
JOURNALCTL_CMD="bash $stub_dir/journalctl.sh" \
    bash "$SCRIPT_DIR/../scripts/verify.sh" >"$ro_out" 2>&1 || rc=$?
assert_eq "$rc" "0" "verify passes in read-only mode (journal liveness skipped)"
assert_file_contains "$ro_out" "journal liveness check skipped" "journal liveness skipped in RO mode"
assert_file_contains "$ro_out" "service active" "readonly service reported active"
rm "$vault/.livesync/read-only-mode"

finish
