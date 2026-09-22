#!/usr/bin/env bash
# Shared configuration resolution.
# Precedence (highest wins): --flags > environment > config/env.local > defaults
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"

resolve_config() {
    # 1. Capture environment overrides before defaults/env.local can clobber them
    local pre_vault="${VAULT_DIR:-}" pre_upstream="${UPSTREAM_DIR:-}" pre_interval="${SYNC_INTERVAL:-}"

    # 2. Defaults
    VAULT_DIR="$HOME/vault"
    UPSTREAM_DIR="$HOME/opt/obsidian-livesync"
    SYNC_INTERVAL=""
    LIVESYNC_BIN="${LIVESYNC_BIN:-$HOME/.local/bin/livesync-cli}"

    # 3. config/env.local (repo-local, gitignored)
    local env_local="${CONFIG_ENV_LOCAL:-$REPO_DIR/config/env.local}"
    if [[ -f "$env_local" ]]; then
        # shellcheck disable=SC1090
        source "$env_local"
    fi

    # 4. Restore environment overrides
    [[ -n "$pre_vault" ]] && VAULT_DIR="$pre_vault"
    [[ -n "$pre_upstream" ]] && UPSTREAM_DIR="$pre_upstream"
    [[ -n "$pre_interval" ]] && SYNC_INTERVAL="$pre_interval"

    # 5. Flags win last
    REMAINING_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vault)
                [[ -n "${2:-}" ]] || { echo "Error: --vault requires a path" >&2; return 1; }
                VAULT_DIR="$2"; shift 2 ;;
            --upstream)
                [[ -n "${2:-}" ]] || { echo "Error: --upstream requires a path" >&2; return 1; }
                UPSTREAM_DIR="$2"; shift 2 ;;
            --interval)
                [[ -n "${2:-}" ]] || { echo "Error: --interval requires a number" >&2; return 1; }
                SYNC_INTERVAL="$2"; shift 2 ;;
            *) REMAINING_ARGS+=("$1"); shift ;;
        esac
    done

    # 6. Normalise
    VAULT_DIR="${VAULT_DIR/#\~/$HOME}"
    UPSTREAM_DIR="${UPSTREAM_DIR/#\~/$HOME}"
    export REPO_DIR VAULT_DIR UPSTREAM_DIR SYNC_INTERVAL LIVESYNC_BIN
}
