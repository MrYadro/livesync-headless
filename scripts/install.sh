#!/usr/bin/env bash
# Configure settings, preflight-sync, then run the upstream systemd installer.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/settings.sh"
resolve_config "$@"

run_cli() {
    if [[ -n "${LIVESYNC_CLI_CMD:-}" ]]; then
        $LIVESYNC_CLI_CMD "$@"
    else
        node "$UPSTREAM_DIR/src/apps/cli/dist/index.cjs" "$@"
    fi
}

require_secret() { # $1 = env var name, $2 = human prompt label
    if [[ -z "${!1:-}" ]]; then
        if [[ -t 0 ]]; then
            local value
            read -rs -p "$2: " value >&2
            echo >&2
            export "$1=$value"
        else
            echo "Error: $1 is not set and stdin is not a terminal." >&2
            echo "       Export it (or run interactively) and retry." >&2
            exit 1
        fi
    fi
}

if [[ ! -d "$UPSTREAM_DIR/.git" && "${SKIP_BOOTSTRAP:-0}" != "1" ]]; then
    bash "$SCRIPT_DIR/bootstrap.sh" --vault "$VAULT_DIR" --upstream "$UPSTREAM_DIR"
fi

settings="$VAULT_DIR/.livesync/settings.json"
if [[ ! -f "$settings" ]]; then
    echo "[INFO] Creating $settings"
    require_secret COUCHDB_USER "CouchDB user"
    require_secret COUCHDB_PASSWORD "CouchDB password"
    require_secret E2E_PASSPHRASE "E2E passphrase (must match your other devices)"
    create_settings "$settings"
fi

allow_flag=()
if [[ "${ALLOW_PLAINTEXT:-0}" == "1" ]]; then allow_flag=(--allow-plaintext); fi
if ! check_settings "$settings" ${allow_flag[@]+"${allow_flag[@]}"}; then
    echo "Error: settings sanity check failed for $settings (see above)." >&2
    exit 1
fi

preflight_readonly() {
    # Read-only credential check: GET the database endpoint. Cannot write anything.
    local creds url auth
    creds=$(SETTINGS_TARGET="$settings" node <<'NODE'
const s = JSON.parse(require("fs").readFileSync(process.env.SETTINGS_TARGET, "utf8"));
console.log(s.couchDB_URI.replace(/\/$/, "") + "/" + s.couchDB_DBNAME + " " + s.couchDB_USER + ":" + s.couchDB_PASSWORD);
NODE
)
    url="${creds%% *}"; auth="${creds#* }"
    local curl_cmd="${CURL_CMD:-curl}"
    $curl_cmd -sf -u "$auth" "$url" >/dev/null
}

install_readonly_service() {
    local unit_dir="${UNIT_DIR:-$HOME/.config/systemd/user}"
    local systemctl_cmd="${SYSTEMCTL_CMD:-systemctl --user}"
    mkdir -p "$unit_dir"
    cat > "$unit_dir/livesync-readonly.service" <<EOF
[Unit]
Description=livesync-headless read-only pull loop
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=$SCRIPT_DIR/readonly-loop.sh --vault $VAULT_DIR
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
    $systemctl_cmd daemon-reload
    $systemctl_cmd enable --now livesync-readonly.service
    touch "$VAULT_DIR/.livesync/read-only-mode"
}

if [[ "${READ_ONLY:-0}" == "1" ]]; then
    echo "[INFO] READ_ONLY=1: validating credentials with read-only GET (no writes)"
    if ! preflight_readonly; then
        echo "Error: read-only preflight failed - check URI/credentials. Service NOT enabled." >&2
        exit 1
    fi
    echo "[INFO] READ_ONLY=1: installing pull-only service (no daemon, no upstream installer)"
    install_readonly_service
    echo "[INFO] Read-only mode installed: livesync-readonly.service"
    echo "       Use a NON-ADMIN CouchDB user while the write guard is on; see README."
    exit 0
fi

echo "[INFO] Preflight sync (validates credentials before enabling service)..."
if ! run_cli "$VAULT_DIR" sync; then
    echo "Error: preflight sync failed - check URI/credentials/passphrases. Service NOT enabled." >&2
    exit 1
fi

interval_args=()
if [[ -n "$SYNC_INTERVAL" ]]; then
    interval_args=(--interval "$SYNC_INTERVAL")
fi

echo "[INFO] Running upstream installer (systemd user service)..."
bash "$UPSTREAM_DIR/src/apps/cli/deploy/install.sh" --user --vault "$VAULT_DIR" "${interval_args[@]+"${interval_args[@]}"}"

echo "[INFO] Install complete. Check: systemctl --user status livesync-cli"
