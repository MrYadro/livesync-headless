#!/usr/bin/env bash
# Settings creation and sanity checks for livesync-headless.
set -euo pipefail

create_settings() {
    local target="$1"
    local template="${SETTINGS_TEMPLATE:-$REPO_DIR/config/settings.example.json}"
    if [[ ! -f "$template" ]]; then
        echo "Error: settings template not found: $template" >&2
        return 1
    fi
    mkdir -p "$(dirname "$target")"
    cp "$template" "$target"
    SETTINGS_TARGET="$target" node <<'NODE'
const fs = require("fs");
const s = JSON.parse(fs.readFileSync(process.env.SETTINGS_TARGET, "utf8"));
const env = process.env;
if (env.COUCHDB_URI) s.couchDB_URI = env.COUCHDB_URI;
if (env.COUCHDB_DBNAME) s.couchDB_DBNAME = env.COUCHDB_DBNAME;
if (env.COUCHDB_USER) s.couchDB_USER = env.COUCHDB_USER;
if (env.COUCHDB_PASSWORD) s.couchDB_PASSWORD = env.COUCHDB_PASSWORD;
if (env.E2E_PASSPHRASE) s.passphrase = env.E2E_PASSPHRASE;
s.isConfigured = true;
fs.writeFileSync(process.env.SETTINGS_TARGET, JSON.stringify(s, null, 4) + "\n");
NODE
    chmod 600 "$target"
    echo "Created $target"
}

check_settings() {
    local target="$1"; shift || true
    local allow_plaintext=0
    if [[ "${1:-}" == "--allow-plaintext" ]]; then allow_plaintext=1; fi
    if [[ ! -f "$target" ]]; then
        echo "FAIL: settings file missing: $target" >&2
        return 1
    fi
    SETTINGS_TARGET="$target" ALLOW_PLAINTEXT="$allow_plaintext" node <<'NODE'
const fs = require("fs");
const s = JSON.parse(fs.readFileSync(process.env.SETTINGS_TARGET, "utf8"));
let bad = false;
const fail = (m) => { console.error("FAIL: " + m); bad = true; };
if (s.isConfigured !== true) fail("isConfigured is not true");
if (s.usePathObfuscation !== true) fail("usePathObfuscation is not true (must match your other devices)");
if (s.encrypt !== true) {
    if (process.env.ALLOW_PLAINTEXT === "1") {
        console.error("WARN: encrypt is off (--allow-plaintext accepted)");
    } else {
        fail("encrypt is not true (pass --allow-plaintext to accept)");
    }
}
process.exit(bad ? 1 : 0);
NODE
}
