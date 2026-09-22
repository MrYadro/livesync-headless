#!/usr/bin/env bash
# One read-only pull cycle: sync (remote -> local db) + mirror (db -> fs).
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
resolve_config "$@"

run_cli() {
    if [[ -n "${LIVESYNC_CLI_CMD:-}" ]]; then
        $LIVESYNC_CLI_CMD "$@"
    else
        node "$UPSTREAM_DIR/src/apps/cli/dist/index.cjs" "$@"
    fi
}

run_cli "$VAULT_DIR" sync
run_cli "$VAULT_DIR" mirror
echo "[INFO] pull-once complete"
