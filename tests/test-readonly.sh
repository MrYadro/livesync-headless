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

# curl stub: logs args; GET returns $GET_BODY, others return {"ok":true}
export CURL_LOG="$TEST_TMP/curl.log"
export GET_BODY='{"_id":"_design/__livesync_readonly_guard","_rev":"2-abc"}'
cat > "$TEST_TMP/curl.sh" <<'EOS'
#!/usr/bin/env bash
echo "curl: $*" >> "${CURL_LOG:?}"
for a in "$@"; do
    if [[ "$prev" == "-u" ]]; then echo "curl-auth: $a" >> "$CURL_LOG"; fi
    prev="$a"
done
if [[ "${1:-}" == "-sf" ]]; then echo "$GET_BODY"; else echo '{"ok":true}'; fi
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

# 3. off (guard absent) -> clean exit, no DELETE
export GET_BODY='{"error":"not_found"}'
: > "$CURL_LOG"
assert_exit_code 0 run_guard off
if grep -q -- "-X DELETE" "$CURL_LOG"; then fail "no DELETE when guard absent"; else ok "no DELETE when guard absent"; fi

# 4. bad subcommand -> usage error
assert_exit_code 1 run_guard nonsense
ok "rejects unknown subcommand"

# 5. pull-once runs sync then mirror via the CLI
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
