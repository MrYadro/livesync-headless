#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/../scripts/lib/config.sh"

uri="obsidian://setuplivesync?0=testpayload"
export CLI_LOG="$TEST_TMP/cli.log"

cat > "$TEST_TMP/cli.sh" <<'EOS'
#!/usr/bin/env bash
db="$1"; shift
echo "cli: $db $*" >> "${CLI_LOG:?}"
IFS= read -r line < /dev/stdin
echo "cli-stdin: $line" >> "$CLI_LOG"
if [[ -n "${CLI_FAIL:-}" ]]; then exit 1; fi
mkdir -p "$db/.livesync"
cat > "$db/.livesync/settings.json" <<'EOT'
{
    "couchDB_URI": "http://127.0.0.1:15984",
    "couchDB_DBNAME": "testdb",
    "encrypt": true,
    "passphrase": "decrypted-secret",
    "usePathObfuscation": true,
    "customChunkSize": 60,
    "usePluginSyncV2": true,
    "isConfigured": true
}
EOT
exit 0
EOS
chmod +x "$TEST_TMP/cli.sh"

run_check() {
    REPO_DIR="$SCRIPT_DIR/.." LIVESYNC_CLI_CMD="bash $TEST_TMP/cli.sh" \
        bash "$SCRIPT_DIR/../scripts/check-uri.sh" "$@"
}

# 1. happy path: parses via the CLI, prints summary, temp dir cleaned up
: > "$CLI_LOG"
out=$(SETUP_URI_PASSPHRASE="uri-pass" run_check "$uri" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "check-uri succeeds on a good URI"
assert_file_contains <(echo "$out") "OK: URI parsed and decrypted" "reports success"
assert_file_contains <(echo "$out") "customChunkSize: 60" "reveals carried settings"
assert_file_contains "$CLI_LOG" "cli-stdin: uri-pass" "passphrase piped on stdin"
db_used=$(awk '{print $2}' "$CLI_LOG" | head -1)
if [[ -d "$db_used" ]]; then fail "temp database dir left behind"; else ok "temp database dir cleaned up"; fi

# 2. bad prefix -> friendly error
out=$(SETUP_URI_PASSPHRASE="x" run_check "https://evil.example/" </dev/null 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "rejects non-setuplivesync URI"
assert_file_contains <(echo "$out") "obsidian://setuplivesync" "error explains the expected prefix"

# 3. CLI failure (decode fails) -> FAIL message, exit 1
export CLI_FAIL=1
rc=0; SETUP_URI_PASSPHRASE="uri-pass" run_check "$uri" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "decode failure exits non-zero"
unset CLI_FAIL

# 4. missing passphrase non-tty -> error naming the variable
out=$(run_check "$uri" </dev/null 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "aborts without passphrase in non-tty mode"
assert_file_contains <(echo "$out") "SETUP_URI_PASSPHRASE" "error names the missing variable"

# 5. missing URI argument -> usage error
assert_exit_code 1 run_check
ok "missing URI exits with usage error"

finish
