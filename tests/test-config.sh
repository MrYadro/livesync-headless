#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/lib/config.sh"

# 1. defaults
unset VAULT_DIR UPSTREAM_DIR SYNC_INTERVAL LIVESYNC_BIN || true
resolve_config
assert_eq "$VAULT_DIR" "$HOME/vault" "default VAULT_DIR is ~/vault"
assert_eq "${SYNC_INTERVAL:-}" "" "default SYNC_INTERVAL empty (LiveSync mode)"

# 2. env.local applies
unset VAULT_DIR UPSTREAM_DIR SYNC_INTERVAL || true
printf 'VAULT_DIR=%s\nUPSTREAM_DIR=%s\n' "$TEST_TMP/vault-local" "$TEST_TMP/upstream-local" \
    > "$TEST_TMP/env.local"
CONFIG_ENV_LOCAL="$TEST_TMP/env.local" resolve_config
assert_eq "$VAULT_DIR" "$TEST_TMP/vault-local" "env.local sets VAULT_DIR"

# 3. env var beats env.local
unset VAULT_DIR UPSTREAM_DIR SYNC_INTERVAL || true
VAULT_DIR="$TEST_TMP/vault-env" CONFIG_ENV_LOCAL="$TEST_TMP/env.local" resolve_config
assert_eq "$VAULT_DIR" "$TEST_TMP/vault-env" "environment beats env.local"

# 4. flag beats env
VAULT_DIR="$TEST_TMP/vault-env" resolve_config --vault "$TEST_TMP/vault-flag"
assert_eq "$VAULT_DIR" "$TEST_TMP/vault-flag" "--vault flag beats environment"

# 5. interval flag
resolve_config --interval 30
assert_eq "$SYNC_INTERVAL" "30" "--interval parsed"

# 6. unknown args preserved
resolve_config --vault "$TEST_TMP/v" daemon extra
assert_eq "${REMAINING_ARGS[*]}" "daemon extra" "unknown args land in REMAINING_ARGS"

# 7. tilde expansion
resolve_config --vault '~/myvault'
assert_eq "$VAULT_DIR" "$HOME/myvault" "tilde expanded in --vault"

# 8. .gitignore covers secrets (Review Focus: secret leakage)
assert_file_contains "$SCRIPT_DIR/../.gitignore" "config/env.local" "gitignore: config/env.local"
assert_file_contains "$SCRIPT_DIR/../.gitignore" "settings.json" "gitignore: settings.json"

# 9. REPO_DIR override respected (used by Task 6 tests)
REPO_DIR="$TEST_TMP/fake-repo" resolve_config
assert_eq "$REPO_DIR" "$TEST_TMP/fake-repo" "pre-set REPO_DIR is respected"

finish
