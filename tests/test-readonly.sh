#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/../scripts/lib/config.sh"
source "$SCRIPT_DIR/../scripts/lib/settings.sh"

vault="$TEST_TMP/vault"
COUCHDB_URI="http://127.0.0.1:15984" COUCHDB_DBNAME="testdb" \
COUCHDB_USER="reader" COUCHDB_PASSWORD="readerpass" \
E2E_PASSPHRASE="e" OBFUSCATE_PASSPHRASE="o" \
    create_settings "$vault/.livesync/settings.json"

# curl stub: logs args; GET (no -X) exits ${GET_RC:-0} with -w http code line
# (${GET_HTTP:-404} when GET_RC=22, else ${GET_HTTP:-200}); mutations succeed.
export CURL_LOG="$TEST_TMP/curl.log"
export GET_BODY='{"_id":"_design/__livesync_readonly_guard","_rev":"2-abc"}'
cat > "$TEST_TMP/curl.sh" <<'EOS'
#!/usr/bin/env bash
echo "curl: $*" >> "${CURL_LOG:?}"
prev=""
for a in "$@"; do
    if [[ "$prev" == "-u" ]]; then echo "curl-auth: $a" >> "$CURL_LOG"; fi
    prev="$a"
done
for a in "$@"; do
    if [[ "$a" == "-X" ]]; then echo '{"ok":true}'; exit 0; fi
done
http="${GET_HTTP:-200}"
if [[ "${GET_RC:-0}" == "22" && -z "${GET_HTTP:-}" ]]; then http=404; fi
printf '%s\n%s\n' "${GET_BODY:-}" "$http"
exit "${GET_RC:-0}"
EOS
chmod +x "$TEST_TMP/curl.sh"

run_guard() {
    VAULT_DIR="$vault" REPO_DIR="$SCRIPT_DIR/.." \
    COUCHDB_ADMIN_USER="admin" COUCHDB_ADMIN_PASSWORD="adminpass" \
    CURL_CMD="bash $TEST_TMP/curl.sh" \
        bash "$SCRIPT_DIR/../scripts/couchdb-readonly.sh" "$@"
}

# 1. Review Focus: on -> PUT guard doc with validate_doc_update and rev
: > "$CURL_LOG"
assert_exit_code 0 run_guard on
assert_file_contains "$CURL_LOG" "-X PUT" "guard uses PUT"
assert_file_contains "$CURL_LOG" "__livesync_readonly_guard" "targets the guard doc id"
assert_file_contains "$CURL_LOG" "validate_doc_update" "body contains the validator"
assert_file_contains "$CURL_LOG" "curl-auth: admin:" "uses admin credentials"

# 2. off (rev present) -> DELETE with rev
: > "$CURL_LOG"
assert_exit_code 0 run_guard off
assert_file_contains "$CURL_LOG" "-X DELETE" "off uses DELETE"
assert_file_contains "$CURL_LOG" "rev=2-abc" "off passes the current rev"

# 3. off (guard absent, HTTP 404) -> clean exit, no DELETE
export GET_RC=22
export GET_BODY='{"error":"not_found"}'
off_out="$TEST_TMP/off.out"
: > "$CURL_LOG"
rc=0; run_guard off >"$off_out" 2>&1 || rc=$?
assert_eq "$rc" "0" "off exits 0 when guard absent (404)"
assert_file_contains "$off_out" "already absent" "off reports guard already absent"
if grep -q -- "-X DELETE" "$CURL_LOG"; then fail "no DELETE when guard absent"; else ok "no DELETE when guard absent"; fi

# 3a. Review Focus: curl transport failure (e.g. connection refused) -> hard fail, no silent success
export GET_RC=7
: > "$CURL_LOG"
rc=0; run_guard off >"$off_out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then ok "off fails non-zero on curl exit 7"; else fail "off fails non-zero on curl exit 7"; fi
if grep -qF "already absent" "$off_out"; then fail "no 'already absent' on transport error"; else ok "no 'already absent' on transport error"; fi
assert_file_contains "$off_out" "curl exit 7" "error names the curl exit code"

# 3b. Review Focus: HTTP error that is NOT 404 (e.g. 401 wrong admin password) -> hard fail
export GET_HTTP=401
: > "$CURL_LOG"
rc=0; run_guard off >"$off_out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then ok "off fails non-zero on HTTP 401"; else fail "off fails non-zero on HTTP 401"; fi
if grep -qF "already absent" "$off_out"; then fail "no 'already absent' on HTTP 401"; else ok "no 'already absent' on HTTP 401"; fi
if grep -q -- "-X DELETE" "$CURL_LOG"; then fail "no DELETE on HTTP 401"; else ok "no DELETE on HTTP 401"; fi
unset GET_HTTP
unset GET_RC GET_BODY

# 4. bad subcommand -> usage error
assert_exit_code 1 run_guard nonsense
ok "rejects unknown subcommand"

# 5. missing admin creds (non-tty) -> friendly error, not unbound variable
creds_out="$TEST_TMP/missing-creds.out"; rc=0
env -u COUCHDB_ADMIN_USER -u COUCHDB_ADMIN_PASSWORD \
    VAULT_DIR="$vault" REPO_DIR="$SCRIPT_DIR/.." \
    CURL_CMD="bash $TEST_TMP/curl.sh" \
    bash "$SCRIPT_DIR/../scripts/couchdb-readonly.sh" on </dev/null >"$creds_out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then ok "missing admin creds exits non-zero"; else fail "missing admin creds exits non-zero"; fi
if grep -qF -- "unbound variable" "$creds_out"; then fail "fails with friendly error, not unbound variable"; else ok "fails with friendly error, not unbound variable"; fi
assert_file_contains "$creds_out" "COUCHDB_ADMIN_USER / COUCHDB_ADMIN_PASSWORD not set" "error names the admin variables"

# 5a. Review Focus: user set but password unset (non-tty) -> friendly error, no unbound-variable crash
creds_out="$TEST_TMP/missing-pw.out"; rc=0
env -u COUCHDB_ADMIN_PASSWORD COUCHDB_ADMIN_USER="admin" \
    VAULT_DIR="$vault" REPO_DIR="$SCRIPT_DIR/.." \
    CURL_CMD="bash $TEST_TMP/curl.sh" \
    bash "$SCRIPT_DIR/../scripts/couchdb-readonly.sh" off </dev/null >"$creds_out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then ok "unset password exits non-zero"; else fail "unset password exits non-zero"; fi
if grep -qF -- "unbound variable" "$creds_out"; then fail "no unbound variable with password unset"; else ok "no unbound variable with password unset"; fi
assert_file_contains "$creds_out" "COUCHDB_ADMIN_USER / COUCHDB_ADMIN_PASSWORD not set" "error names both admin variables"

# 6. pull-once runs sync then mirror via the CLI
export CLI_LOG="$TEST_TMP/cli.log"; : > "$CLI_LOG"
cat > "$TEST_TMP/cli.sh" <<'EOS'
#!/usr/bin/env bash
echo "cli: $*" >> "${CLI_LOG:?}"
exit 0
EOS
chmod +x "$TEST_TMP/cli.sh"
assert_exit_code 0 env VAULT_DIR="$vault" REPO_DIR="$SCRIPT_DIR/.." \
    LIVESYNC_CLI_CMD="bash $TEST_TMP/cli.sh" \
    UPSTREAM_DIR="$TEST_TMP/up" bash "$SCRIPT_DIR/../scripts/pull-once.sh"
assert_file_contains "$CLI_LOG" "sync" "pull-once runs sync"
assert_file_contains "$CLI_LOG" "mirror" "pull-once runs mirror"

finish
