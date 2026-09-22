#!/usr/bin/env bash
# Install/remove the CouchDB write guard used by READ_ONLY test mode.
# Usage: couchdb-readonly.sh on|off [--vault <path>]
# Admin credentials from COUCHDB_ADMIN_USER / COUCHDB_ADMIN_PASSWORD (prompted if unset).
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
resolve_config "$@"

action="${REMAINING_ARGS[0]:-}"
if [[ "$action" != "on" && "$action" != "off" ]]; then
    echo "Usage: $0 on|off" >&2
    exit 1
fi

settings="$VAULT_DIR/.livesync/settings.json"
if [[ ! -f "$settings" ]]; then
    echo "Error: $settings not found - run install first" >&2
    exit 1
fi

require_admin() {
    if [[ -z "${COUCHDB_ADMIN_USER:-}" || ${#COUCHDB_ADMIN_PASSWORD} -eq 0 ]]; then
        if [[ -t 0 ]]; then
            [[ -z "${COUCHDB_ADMIN_USER:-}" ]] && read -rp "CouchDB admin user: " COUCHDB_ADMIN_USER
            [[ ${#COUCHDB_ADMIN_PASSWORD} -eq 0 ]] && read -rsp "CouchDB admin password: " COUCHDB_ADMIN_PASSWORD >&2 && echo >&2
            export COUCHDB_ADMIN_USER COUCHDB_ADMIN_PASSWORD
        else
            echo "Error: COUCHDB_ADMIN_USER / COUCHDB_ADMIN_PASSWORD not set and stdin is not a terminal." >&2
            exit 1
        fi
    fi
}

read -r db_url db_name < <(SETTINGS_TARGET="$settings" node <<'NODE'
const s = JSON.parse(require("fs").readFileSync(process.env.SETTINGS_TARGET, "utf8"));
console.log(s.couchDB_URI.replace(/\/$/, ""), s.couchDB_DBNAME);
NODE
)

curl_cmd="${CURL_CMD:-curl}"
guard_url="$db_url/$db_name/_design/__livesync_readonly_guard"

guard_rev() { # echoes current _rev, or empty if absent
    local body
    body=$($curl_cmd -sf -u "$auth" "$guard_url" 2>/dev/null || true)
    if [[ -n "$body" ]]; then
        echo "$body" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const j=JSON.parse(d);console.log(j._rev||"")}catch(e){console.log("")}})'
    fi
}

require_admin
auth="$COUCHDB_ADMIN_USER:$COUCHDB_ADMIN_PASSWORD"

if [[ "$action" == "on" ]]; then
    rev="$(guard_rev)"
    body="$(GUARD_REV="$rev" node <<'NODE'
const doc = {
    _id: "_design/__livesync_readonly_guard",
    validate_doc_update: "function (newDoc, oldDoc, userCtx) { if (userCtx.roles.indexOf('_admin') !== -1) return; throw { forbidden: 'read-only guard active' }; }"
};
if (process.env.GUARD_REV) doc._rev = process.env.GUARD_REV;
console.log(JSON.stringify(doc));
NODE
)"
    $curl_cmd -sf -u "$auth" -X PUT -H 'Content-Type: application/json' -d "$body" "$guard_url" >/dev/null
    echo "[INFO] Read-only guard ON: non-admin writes to $db_name are now rejected."
    echo "       WARNING: this blocks ALL non-admin writers, including other devices."
else
    rev="$(guard_rev)"
    if [[ -z "$rev" ]]; then
        echo "[INFO] Guard already absent from $db_name."
        exit 0
    fi
    $curl_cmd -sf -u "$auth" -X DELETE "$guard_url?rev=$rev" >/dev/null
    echo "[INFO] Read-only guard OFF: writes to $db_name are allowed again."
fi
