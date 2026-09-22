#!/usr/bin/env bash
# Update to the pin recorded in upstream.pin: rebuild, reinstall, verify.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
resolve_config "$@"

PIN="$(tr -d '[:space:]' < "$REPO_DIR/upstream.pin")"
record="$UPSTREAM_DIR/.livesync-headless-pin"

if [[ -f "$record" ]]; then
    installed="$(tr -d '[:space:]' < "$record")"
    if [[ "$installed" == "$PIN" ]]; then
        echo "Nothing to do: already at pin $PIN." >&2
        echo "Edit upstream.pin to the target tag, then re-run." >&2
        exit 1
    fi
    echo "[INFO] Updating: $installed -> $PIN"
else
    echo "[INFO] No recorded pin; updating to $PIN"
fi

if [[ -f "$VAULT_DIR/.livesync/read-only-mode" && "${READ_ONLY:-0}" != "1" ]]; then
    echo "Error: Read-only install detected. Re-run as: READ_ONLY=1 make update (or remove the marker to switch to full sync)." >&2
    exit 1
fi

bash "$SCRIPT_DIR/bootstrap.sh" --vault "$VAULT_DIR" --upstream "$UPSTREAM_DIR"

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
    bash "$SCRIPT_DIR/install.sh" --vault "$VAULT_DIR" --upstream "$UPSTREAM_DIR"
else
    echo "[INFO] SKIP_INSTALL=1, skipping reinstall"
fi

if [[ "${SKIP_VERIFY:-0}" != "1" ]]; then
    bash "$SCRIPT_DIR/verify.sh" --vault "$VAULT_DIR" --upstream "$UPSTREAM_DIR"
else
    echo "[INFO] SKIP_VERIFY=1, skipping verify"
fi

echo "[INFO] Update to $PIN complete"
