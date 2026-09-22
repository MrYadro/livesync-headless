#!/usr/bin/env bash
# Healthcheck for the livesync-cli service. Non-zero exit on hard failure.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/settings.sh"
resolve_config "$@"

systemctl_cmd="${SYSTEMCTL_CMD:-systemctl --user}"
journalctl_cmd="${JOURNALCTL_CMD:-journalctl --user -u livesync-cli -n 50 --no-pager}"

fail_count=0
hard_fail() { echo "FAIL: $1" >&2; fail_count=$((fail_count + 1)); }

# 1. Service active
if $systemctl_cmd is-active livesync-cli >/dev/null 2>&1; then
    echo "OK: service active"
else
    hard_fail "service livesync-cli is not active"
fi

# 2. Settings sanity (hard; ALLOW_PLAINTEXT=1 downgrades encrypt)
allow_flag=()
if [[ "${ALLOW_PLAINTEXT:-0}" == "1" ]]; then allow_flag=(--allow-plaintext); fi
if check_settings "$VAULT_DIR/.livesync/settings.json" ${allow_flag[@]+"${allow_flag[@]}"}; then
    echo "OK: settings sane"
else
    hard_fail "settings check failed for $VAULT_DIR/.livesync/settings.json"
fi

# 3. Local DB roundtrip (hard)
run_cli() {
    if [[ -n "${LIVESYNC_CLI_CMD:-}" ]]; then
        $LIVESYNC_CLI_CMD "$@"
    else
        "$LIVESYNC_BIN" "$@"
    fi
}
if run_cli "$VAULT_DIR" ls >/dev/null 2>&1; then
    echo "OK: local database reachable (ls)"
else
    hard_fail "livesync-cli ls failed against $VAULT_DIR"
fi

# 4. Journal scan (warn-only)
if $journalctl_cmd 2>/dev/null | grep -qiE 'error|fatal'; then
    echo "WARN: error-like lines in recent journal (see: journalctl --user -u livesync-cli -n 50)"
fi

if [[ "$fail_count" -gt 0 ]]; then
    echo "verify: $fail_count hard failure(s)" >&2
    exit 1
fi
echo "verify: all checks passed"
