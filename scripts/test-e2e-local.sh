#!/usr/bin/env bash
# Local e2e: throwaway CouchDB + two temp vaults; proves bidirectional sync
# with E2E encryption and path obfuscation enabled. Never touches production.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
resolve_config "$@"

CLI="$UPSTREAM_DIR/src/apps/cli/dist/index.cjs"
if [[ ! -f "$CLI" ]]; then
    echo "FAIL: CLI not built at $CLI - run: make bootstrap" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP: Docker not available - e2e test not run"
    exit 0
fi

COUCH_PORT=15984
COUCH_NAME=livesync-headless-e2e
# Synthetic throwaway credentials for the local container only.
COUCH_ADMIN="admin"
COUCH_ADMIN_PW="testpass-e2e"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/livesync-e2e.XXXXXX")"
cleanup() {
    [[ -n "${DAEMON_PID:-}" ]] && kill "$DAEMON_PID" 2>/dev/null || true
    docker rm -f "$COUCH_NAME" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "[INFO] Starting CouchDB container..."
docker run -d --rm --name "$COUCH_NAME" -p "$COUCH_PORT:5984" \
    -e COUCHDB_USER="$COUCH_ADMIN" -e COUCHDB_PASSWORD="$COUCH_ADMIN_PW" couchdb:3 >/dev/null

echo "[INFO] Waiting for CouchDB..."
for i in $(seq 1 60); do
    if curl -sf -u "$COUCH_ADMIN:$COUCH_ADMIN_PW" "http://127.0.0.1:$COUCH_PORT/" >/dev/null 2>&1; then break; fi
    sleep 1
done
curl -sf -u "$COUCH_ADMIN:$COUCH_ADMIN_PW" -X POST "http://127.0.0.1:$COUCH_PORT/_cluster_setup" \
    -H 'Content-Type: application/json' -d '{"action":"enable_single_node"}' >/dev/null \
    || { echo "FAIL: could not initialise CouchDB single node" >&2; exit 1; }
curl -sf -u "$COUCH_ADMIN:$COUCH_ADMIN_PW" -X PUT "http://127.0.0.1:$COUCH_PORT/obsidian-livesync-e2e" >/dev/null \
    || { echo "FAIL: could not create test database" >&2; exit 1; }

mk_vault() { # $1 = dir
    mkdir -p "$1/.livesync"
    cat > "$1/.livesync/settings.json" <<EOF
{
    "couchDB_URI": "http://127.0.0.1:$COUCH_PORT",
    "couchDB_DBNAME": "obsidian-livesync-e2e",
    "couchDB_USER": "$COUCH_ADMIN",
    "couchDB_PASSWORD": "$COUCH_ADMIN_PW",
    "encrypt": true,
    "passphrase": "e2e-local-secret",
    "usePathObfuscation": true,
    "obfuscatePassphrase": "obf-local-secret",
    "liveSync": true,
    "syncOnSave": true,
    "syncOnStart": true,
    "isConfigured": true
}
EOF
    chmod 600 "$1/.livesync/settings.json"
}

VAULT_A="$TMP/vault-a"; VAULT_B="$TMP/vault-b"
mk_vault "$VAULT_A"; mk_vault "$VAULT_B"

echo "[INFO] Initial sync of both vaults..."
node "$CLI" "$VAULT_A" sync >/dev/null
node "$CLI" "$VAULT_B" sync >/dev/null

echo "[INFO] Starting daemon on vault A..."
node "$CLI" "$VAULT_A" daemon &
DAEMON_PID=$!

wait_for_file() { # $1 = vault, $2 = path, $3 = content, $4 = timeout_s
    local deadline=$(( $(date +%s) + $4 ))
    while (( $(date +%s) < deadline )); do
        if [[ -f "$1/$2" ]] && grep -qF "$3" "$1/$2"; then return 0; fi
        node "$CLI" "$1" sync >/dev/null 2>&1 || true
        sleep 2
    done
    return 1
}

echo "[INFO] A -> B: write in A, expect in B"
mkdir -p "$VAULT_A/notes"
echo "hello from A" > "$VAULT_A/notes/from-a.md"
if wait_for_file "$VAULT_B" "notes/from-a.md" "hello from A" 90; then
    echo "OK: A -> B"
else
    echo "FAIL: file written in A never appeared in B" >&2; exit 1
fi

echo "[INFO] B -> A: write in B, expect in A (daemon side)"
mkdir -p "$VAULT_B/notes"
echo "hello from B" > "$VAULT_B/notes/from-b.md"
if wait_for_file "$VAULT_A" "notes/from-b.md" "hello from B" 90; then
    echo "OK: B -> A"
else
    echo "FAIL: file written in B never appeared in A" >&2; exit 1
fi

echo "PASS: bidirectional sync verified locally (E2E + obfuscation on)"
