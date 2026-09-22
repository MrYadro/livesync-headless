#!/usr/bin/env bash
# Pull-only loop for READ_ONLY mode: sync (remote -> local db) then mirror (db -> fs).
# Any attempted remote writes are rejected by the CouchDB write guard (see couchdb-readonly.sh).
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
resolve_config "$@"
interval="${SYNC_INTERVAL:-60}"

run_cli() {
    if [[ -n "${LIVESYNC_CLI_CMD:-}" ]]; then
        $LIVESYNC_CLI_CMD "$@"
    else
        node "$UPSTREAM_DIR/src/apps/cli/dist/index.cjs" "$@"
    fi
}

while true; do
    echo "[INFO] $(date -u +%FT%TZ) pull cycle: sync + mirror"
    if ! run_cli "$VAULT_DIR" sync; then
        echo "[WARN] sync cycle failed; retrying next interval" >&2
    else
        run_cli "$VAULT_DIR" mirror
    fi
    sleep "$interval"
done
