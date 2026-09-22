#!/usr/bin/env bash
# Healthcheck for the livesync-cli service. Non-zero exit on hard failure.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/settings.sh"
resolve_config "$@"

systemctl_cmd="${SYSTEMCTL_CMD:-systemctl --user}"
journalctl_cmd="${JOURNALCTL_CMD:-journalctl --user -u livesync-cli -n 50 --no-pager}"

ro_mode=0
if [[ -f "$VAULT_DIR/.livesync/read-only-mode" ]]; then ro_mode=1; fi

fail_count=0
hard_fail() { echo "FAIL: $1" >&2; fail_count=$((fail_count + 1)); }

# 1. Service active (read-only installs run livesync-readonly.service)
service_name=livesync-cli
if [[ "$ro_mode" -eq 1 ]]; then service_name=livesync-readonly.service; fi
if $systemctl_cmd is-active "$service_name" >/dev/null 2>&1; then
    echo "OK: service active"
else
    hard_fail "service $service_name is not active"
fi

# 2. Settings sanity (hard; ALLOW_PLAINTEXT=1 downgrades encrypt)
allow_flag=()
if [[ "${ALLOW_PLAINTEXT:-0}" == "1" ]]; then allow_flag=(--allow-plaintext); fi
if check_settings "$VAULT_DIR/.livesync/settings.json" ${allow_flag[@]+"${allow_flag[@]}"}; then
    echo "OK: settings sane"
else
    hard_fail "settings check failed for $VAULT_DIR/.livesync/settings.json"
fi

# 3. Local DB present + daemon live state (hard).
#    A second CLI process cannot open the local database while the daemon owns
#    it (single-writer), so we probe the database directory and the journal
#    instead of invoking livesync-cli.
if [[ -d "$VAULT_DIR/.livesync/runtime" ]]; then
    echo "OK: local database present"
else
    hard_fail "local database directory missing: $VAULT_DIR/.livesync/runtime"
fi
if [[ "$ro_mode" -eq 1 ]]; then
    echo "OK: local database present (read-only mode; journal liveness check skipped)"
elif $journalctl_cmd 2>/dev/null | grep -qE "LiveSync active|Replicating with remote|pull cycle"; then
    echo "OK: daemon reached live state (journal)"
else
    hard_fail "no live-state journal lines (see: journalctl --user -u livesync-cli -n 50)"
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
