#!/usr/bin/env bash
# Parse and decrypt a Setup URI WITHOUT touching the real vault: runs the CLI's
# own `setup` command against a throwaway database directory, prints the
# non-secret settings the URI carries, then deletes the directory.
# Usage: check-uri.sh "<setup-uri>" [--vault <path> is NOT used - real vault untouched]
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
resolve_config "$@"

uri="${REMAINING_ARGS[0]:-}"
if [[ -z "$uri" ]]; then
    echo "Usage: $0 <setup-uri>" >&2
    exit 1
fi
if [[ "$uri" != obsidian://setuplivesync?* ]]; then
    echo "Error: setup URI must start with obsidian://setuplivesync?" >&2
    exit 1
fi

if [[ -z "${SETUP_URI_PASSPHRASE+x}" ]] || [[ -z "$SETUP_URI_PASSPHRASE" ]]; then
    if [[ -t 0 ]]; then
        read -rsp "Setup URI passphrase: " SETUP_URI_PASSPHRASE >&2 && echo >&2
        export SETUP_URI_PASSPHRASE
    else
        echo "Error: SETUP_URI_PASSPHRASE not set and stdin is not a terminal." >&2
        exit 1
    fi
fi

run_cli() {
    if [[ -n "${LIVESYNC_CLI_CMD:-}" ]]; then
        $LIVESYNC_CLI_CMD "$@"
    else
        node "$UPSTREAM_DIR/src/apps/cli/dist/index.cjs" "$@"
    fi
}

TMP_DB="$(mktemp -d "${TMPDIR:-/tmp}/livesync-check-uri.XXXXXX")"
trap 'rm -rf "$TMP_DB"' EXIT

if ! printf '%s\n' "$SETUP_URI_PASSPHRASE" | run_cli "$TMP_DB" setup "$uri" >/dev/null 2>&1; then
    echo "FAIL: URI could not be parsed/decrypted (wrong passphrase or corrupted payload)." >&2
    exit 1
fi

SETTINGS_TARGET="$TMP_DB/.livesync/settings.json" node <<'NODE'
const fs = require("fs");
const s = JSON.parse(fs.readFileSync(process.env.SETTINGS_TARGET, "utf8"));
const interesting = [
    "couchDB_URI", "couchDB_DBNAME", "encrypt", "usePathObfuscation",
    "customChunkSize", "usePluginSyncV2", "handleFilenameCaseSensitive", "isConfigured",
];
console.log("OK: URI parsed and decrypted. Settings it carries:");
for (const k of interesting) {
    if (k in s) console.log(`  ${k}: ${s[k]}`);
}
if (!("customChunkSize" in s)) console.log("  customChunkSize: (absent -> 0/default)");
NODE
