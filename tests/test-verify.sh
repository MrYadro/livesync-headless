#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/../scripts/lib/config.sh"
source "$SCRIPT_DIR/../scripts/lib/settings.sh"

vault="$TEST_TMP/vault"
mkdir -p "$vault"
COUCHDB_USER=u COUCHDB_PASSWORD=p E2E_PASSPHRASE=e OBFUSCATE_PASSPHRASE=o \
    create_settings "$vault/.livesync/settings.json"

stub_dir="$TEST_TMP/stubs"
mkdir -p "$stub_dir"

run_verify() {
    VAULT_DIR="$vault" REPO_DIR="$SCRIPT_DIR/.." \
    SYSTEMCTL_CMD="bash $stub_dir/systemctl.sh" \
    JOURNALCTL_CMD="bash $stub_dir/journalctl.sh" \
    LIVESYNC_CLI_CMD="bash $stub_dir/cli.sh" \
        bash "$SCRIPT_DIR/../scripts/verify.sh"
}

# systemctl stub: active unless SERVICE_INACTIVE=1
cat > "$stub_dir/systemctl.sh" <<'EOS'
#!/usr/bin/env bash
[[ "${SERVICE_INACTIVE:-0}" == "1" ]] && exit 1
[[ "$1 $2" == "is-active livesync-cli" ]] || { echo "unexpected systemctl args: $*" >&2; exit 2; }
exit 0
EOS
cat > "$stub_dir/journalctl.sh" <<'EOS'
#!/usr/bin/env bash
[[ "${JOURNAL_ERRORS:-0}" == "1" ]] && echo "Sep 23 10:00:00 host livesync-cli[1]: some error happened"
exit 0
EOS
cat > "$stub_dir/cli.sh" <<'EOS'
#!/usr/bin/env bash
[[ "${CLI_FAIL:-0}" == "1" ]] && exit 1
[[ "$2" == "ls" ]] || { echo "unexpected cli args: $*" >&2; exit 2; }
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

# 4. cli ls failing -> non-zero
export CLI_FAIL=1
rc=0; run_verify || rc=$?
assert_eq "$rc" "1" "verify fails when cli ls fails"
unset CLI_FAIL

# 5. journal errors -> warning only, still exit 0
export JOURNAL_ERRORS=1
assert_exit_code 0 run_verify
ok "journal errors are warn-only"
unset JOURNAL_ERRORS

# 6. ALLOW_PLAINTEXT=1 downgrades encrypt check
sed -i.bak 's/"encrypt": true/"encrypt": false/' "$vault/.livesync/settings.json"
assert_exit_code 1 run_verify
ok "encrypt off fails by default"
export ALLOW_PLAINTEXT=1
assert_exit_code 0 run_verify
ok "encrypt off passes with ALLOW_PLAINTEXT=1"
unset ALLOW_PLAINTEXT

finish
