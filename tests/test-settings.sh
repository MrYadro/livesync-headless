#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/../scripts/lib/config.sh"
source "$SCRIPT_DIR/../scripts/lib/settings.sh"

target="$TEST_TMP/.livesync/settings.json"

# 1. create_settings fills env secrets, sets isConfigured, keeps E2E+obfuscation on
#    (expected values are read back from the same env vars - no literal comparison)
export COUCHDB_URI="http://127.0.0.1:15984" COUCHDB_DBNAME="testdb" COUCHDB_USER="admin" \
    COUCHDB_PASSWORD="testpass-e2e" E2E_PASSPHRASE="e2e-secret"
create_settings "$target"

T="$target" assert_exit_code 0 node -e '
    const s = JSON.parse(require("fs").readFileSync(process.env.T, "utf8"));
    const want = {couchDB_URI: process.env.COUCHDB_URI, couchDB_DBNAME: process.env.COUCHDB_DBNAME,
        couchDB_USER: process.env.COUCHDB_USER, couchDB_PASSWORD: process.env.COUCHDB_PASSWORD,
        passphrase: process.env.E2E_PASSPHRASE,
        isConfigured: true, encrypt: true, usePathObfuscation: true};
    for (const k in want) if (s[k] !== want[k]) { console.error("mismatch: " + k); process.exit(1); }
    if ("obfuscatePassphrase" in s) { console.error("dead key obfuscatePassphrase written"); process.exit(1); }
' && ok "create_settings fills secrets, flags on, no dead obfuscatePassphrase key"

# 2. Review Focus: settings file mode 0600
mode=$(stat -f '%Lp' "$target" 2>/dev/null || stat -c '%a' "$target")
assert_eq "$mode" "600" "settings file mode is 0600"

# 3. check_settings passes on a good file
assert_exit_code 0 check_settings "$target"
ok "check_settings passes good file"

# 4. Review Focus: obfuscation off -> hard fail (silent-desync guard)
sed 's/"usePathObfuscation": true/"usePathObfuscation": false/' "$target" > "$TEST_TMP/bad-obf.json"
assert_exit_code 1 check_settings "$TEST_TMP/bad-obf.json"
ok "check_settings fails when obfuscation off"

# 5. encrypt off -> hard fail; --allow-plaintext -> pass
sed 's/"encrypt": true/"encrypt": false/' "$target" > "$TEST_TMP/no-e2e.json"
assert_exit_code 1 check_settings "$TEST_TMP/no-e2e.json"
ok "check_settings fails when encrypt off"
assert_exit_code 0 check_settings "$TEST_TMP/no-e2e.json" --allow-plaintext
ok "check_settings allows plaintext with --allow-plaintext"

# 6. missing file -> fail
assert_exit_code 1 check_settings "$TEST_TMP/does-not-exist.json"
ok "check_settings fails on missing file"

finish
