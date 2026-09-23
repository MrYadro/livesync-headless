#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/../scripts/lib/config.sh"
source "$SCRIPT_DIR/../scripts/lib/settings.sh"

vault="$TEST_TMP/vault"
uri="obsidian://setuplivesync?0=eyJjb3VjaERCX1VSSSI6Imh0dHA"
export CLI_LOG="$TEST_TMP/cli.log"
export SETTINGS_TO_WRITE="$vault/.livesync/settings.json"

# CLI stub: logs args, reads ONE line from stdin (the passphrase), writes canned
# settings (OBF_OFF=1 writes usePathObfuscation false; CLI_FAIL=1 fails).
cat > "$TEST_TMP/cli.sh" <<'EOS'
#!/usr/bin/env bash
echo "cli-args: $*" >> "${CLI_LOG:?}"
IFS= read -r line < /dev/stdin
echo "cli-stdin: $line" >> "$CLI_LOG"
if [[ -n "${CLI_FAIL:-}" ]]; then exit 1; fi
mkdir -p "$(dirname "${SETTINGS_TO_WRITE:?}")"
cat > "$SETTINGS_TO_WRITE" <<'EOT'
{
    "couchDB_URI": "http://127.0.0.1:15984",
    "couchDB_DBNAME": "testdb",
    "couchDB_USER": "admin",
    "couchDB_PASSWORD": "imported-secret",
    "encrypt": true,
    "passphrase": "imported-e2e",
    "usePathObfuscation": true,
    "liveSync": true,
    "syncOnSave": true,
    "syncOnStart": true,
    "isConfigured": true
}
EOT
if [[ -n "${OBF_OFF:-}" ]]; then
    sed -i.bak 's/"usePathObfuscation": true/"usePathObfuscation": false/' "$SETTINGS_TO_WRITE"
fi
exit 0
EOS
chmod +x "$TEST_TMP/cli.sh"

run_import() {
    VAULT_DIR="$vault" REPO_DIR="$SCRIPT_DIR/.." \
    LIVESYNC_CLI_CMD="bash $TEST_TMP/cli.sh" \
        bash "$SCRIPT_DIR/../scripts/import-uri.sh" "$@"
}

# 1. happy path: URI arg + passphrase on stdin + 0600 + sane settings
: > "$CLI_LOG"
rc=0; SETUP_URI_PASSPHRASE="uri-pass-1" run_import "$uri" || rc=$?
assert_eq "$rc" "0" "imports URI with passphrase"
assert_file_contains "$CLI_LOG" "setup $uri" "passes URI to the setup command"
assert_file_contains "$CLI_LOG" "cli-stdin: uri-pass-1" "pipes passphrase on stdin"
mode=$(stat -f '%Lp' "$SETTINGS_TO_WRITE" 2>/dev/null || stat -c '%a' "$SETTINGS_TO_WRITE")
assert_eq "$mode" "600" "imported settings are 0600"

# 2. non-tty missing passphrase -> friendly error naming the variable
out=$(run_import "$uri" </dev/null 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "aborts without passphrase in non-tty mode"
assert_file_contains <(echo "$out") "SETUP_URI_PASSPHRASE" "error names the missing variable"

# 3. wrong URI prefix -> friendly error
out=$(SETUP_URI_PASSPHRASE="x" run_import "https://evil.example.com/?s=1" </dev/null 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "rejects non-setuplivesync URI"
assert_file_contains <(echo "$out") "obsidian://setuplivesync" "error explains the expected prefix"

# 4. CLI failure -> non-zero
export CLI_FAIL=1
rc=0; SETUP_URI_PASSPHRASE="uri-pass-1" run_import "$uri" || rc=$?
assert_eq "$rc" "1" "setup command failure aborts import"
unset CLI_FAIL

# 5. imported settings with obfuscation off -> rejected (silent-desync guard)
export OBF_OFF=1
rc=0; SETUP_URI_PASSPHRASE="uri-pass-1" run_import "$uri" || rc=$?
assert_eq "$rc" "1" "obfuscation-off settings rejected on import"
unset OBF_OFF

# 6. missing URI argument -> usage error
assert_exit_code 1 run_import
ok "missing URI exits with usage error"

finish
