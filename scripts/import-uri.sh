#!/usr/bin/env bash
# Apply a passphrase-protected obsidian-livesync Setup URI to the vault settings.
# Usage: import-uri.sh "<setup-uri>" [--vault <path>]
# Passphrase: SETUP_URI_PASSPHRASE env (prompted if tty), piped to the CLI on stdin.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/settings.sh"
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

if ! printf '%s\n' "$SETUP_URI_PASSPHRASE" | run_cli "$VAULT_DIR" setup "$uri"; then
    echo "Error: setup command failed - wrong passphrase or malformed URI." >&2
    exit 1
fi

settings="$VAULT_DIR/.livesync/settings.json"
if [[ ! -f "$settings" ]]; then
    echo "Error: $settings was not created by the setup command" >&2
    exit 1
fi
chmod 600 "$settings"

allow_flag=()
if [[ "${ALLOW_PLAINTEXT:-0}" == "1" ]]; then allow_flag=(--allow-plaintext); fi
if ! check_settings "$settings" ${allow_flag[@]+"${allow_flag[@]}"}; then
    echo "Error: imported settings failed sanity checks (see above)." >&2
    exit 1
fi
echo "[INFO] Settings imported from Setup URI: $settings"
