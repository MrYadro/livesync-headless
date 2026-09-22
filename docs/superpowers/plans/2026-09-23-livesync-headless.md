# livesync-headless Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An ops repo that pins, builds, deploys, configures, verifies, and updates the upstream `self-hosted-livesync-cli` as a systemd user service doing live bidirectional sync between a server vault directory and a remote CouchDB.

**Architecture:** No protocol code. Four bash scripts (`bootstrap`, `install`, `update`, `verify`) wrap the upstream CLI's own installer; two shared libs (`config.sh`, `settings.sh`) hold the testable logic. Tests are plain bash scripts under `tests/` using temp dirs, local git fixtures, and command stubs — no network in unit tests.

**Tech Stack:** Bash (`set -euo pipefail`), Node.js ≥ 22 (settings JSON handling + upstream build), git, systemd user units, Docker (optional e2e only).

**Spec:** `docs/superpowers/specs/2026-09-23-livesync-headless-design.md`

## Global Constraints

- Pin exact upstream tag `1.0.30` in `upstream.pin` (spec §11)
- Every script: `set -euo pipefail`; every script sources `scripts/lib/config.sh` and calls `resolve_config "$@"`
- Path resolution order, verbatim from spec §5: `--vault` flag > `VAULT_DIR` env > `config/env.local` > default `~/vault` (same pattern for `UPSTREAM_DIR`, `SYNC_INTERVAL`)
- No secrets in git: `config/settings.example.json` has empty secret fields; live `settings.json` and `config/env.local` are gitignored; settings file mode `0600`
- Default is LiveSync `_changes` mode; polling only when `SYNC_INTERVAL` is set
- `usePathObfuscation: true` and `encrypt: true` in every settings artifact; verify treats them as hard failures
- Unit tests must not touch the network — use local git fixtures and stub commands
- Synthetic secrets only in tests (e.g. `testpass-e2e`) — never real credentials

## Review Focus

Spec-implied failure modes; each is pinned by a test in the owning task:

1. **Precedence inversion** — `config/env.local` must not clobber explicitly exported env vars (owner: Task 1, test `env_var_beats_env_local`)
2. **Secret leakage** — settings file must be `0600` and `settings.json`/`env.local` must be gitignored (owners: Task 2 test `settings_file_mode_0600`, Task 1 test `gitignore_covers_secrets`)
3. **Silent desync from obfuscation off** — `verify.sh` must exit non-zero when `usePathObfuscation` is false (owner: Task 5, test `fails_when_obfuscation_off`)
4. **Dirty upstream clone** — `bootstrap.sh` must abort on a locally modified clone (owner: Task 3, test `refuses_dirty_upstream_tree`)
5. **Bad credentials enabled as a service** — `install.sh` must abort when the preflight `sync` fails, before running the installer (owner: Task 4, test `aborts_when_preflight_sync_fails`)

---

### Task 1: Scaffolding + config resolution library

**Files:**
- Create: `.gitignore`, `upstream.pin`, `config/env.example`, `config/settings.example.json`, `scripts/lib/config.sh`, `tests/lib.sh`, `tests/run-all.sh`, `tests/test-config.sh`, `Makefile`
- Test: `tests/test-config.sh`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `resolve_config "$@"` (in `scripts/lib/config.sh`) setting globals `REPO_DIR`, `VAULT_DIR`, `UPSTREAM_DIR`, `SYNC_INTERVAL`, `LIVESYNC_BIN`, and array `REMAINING_ARGS`; flags `--vault <p>`, `--upstream <p>`, `--interval <n>` are consumed, everything else lands in `REMAINING_ARGS`. `REPO_DIR` = absolute path of repo root. `make test` runs every `tests/test-*.sh`.

- [ ] **Step 1: Write the failing test**

Create `tests/lib.sh` (assertion helpers — used by every later task):

```bash
#!/usr/bin/env bash
# Shared test helpers. tests/test-*.sh source this file.
set -euo pipefail
FAILURES=0
PASSES=0

ok() { PASSES=$((PASSES + 1)); echo "  ok - $1"; }
fail() { FAILURES=$((FAILURES + 1)); echo "  NOT OK - $1" >&2; }

assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3: expected [$2], got [$1]"; fi
}

assert_file_contains() {
    if grep -qF "$2" "$1" 2>/dev/null; then ok "$3"; else fail "$3: file $1 missing [$2]"; fi
}

assert_exit_code() {
    local expected="$1"; shift
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    assert_eq "$got" "$expected" "$1 exits with $expected"
}

finish() {
    echo "-- $PASSES passed, $FAILURES failed"
    [[ "$FAILURES" -eq 0 ]]
}

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/livesync-headless-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT
```

Create `tests/test-config.sh`:

```bash
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
```

Create `tests/run-all.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$SCRIPT_DIR"/test-*.sh; do
    echo "== $(basename "$t")"
    bash "$t" || rc=1
done
exit "$rc"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-config.sh`
Expected: FAIL — `scripts/lib/config.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `.gitignore`:

```
config/env.local
config/settings.json
settings.json
.livesync/
```

Create `upstream.pin` (single line, no trailing spaces):

```
1.0.30
```

Create `config/env.example`:

```bash
# livesync-headless server configuration.
# Copy to config/env.local and adjust. Flags and environment variables override this file.

# Vault directory (the actual markdown files). Default: ~/vault
#VAULT_DIR=/home/user/vault

# Pinned upstream clone/build tree. Default: ~/opt/obsidian-livesync
#UPSTREAM_DIR=/home/user/opt/obsidian-livesync

# Poll CouchDB every N seconds instead of the _changes feed. Default: unset (LiveSync mode)
#SYNC_INTERVAL=
```

Create `config/settings.example.json`:

```json
{
    "couchDB_URI": "https://couch.example.com:5984",
    "couchDB_DBNAME": "obsidian-livesync",
    "couchDB_USER": "",
    "couchDB_PASSWORD": "",
    "encrypt": true,
    "passphrase": "",
    "usePathObfuscation": true,
    "obfuscatePassphrase": "",
    "liveSync": true,
    "syncOnSave": true,
    "syncOnStart": true,
    "isConfigured": false
}
```

Create `scripts/lib/config.sh`:

```bash
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
```

Create `Makefile`:

```make
.PHONY: test
test:
	@bash tests/run-all.sh
```

```bash
chmod +x tests/run-all.sh tests/test-config.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-config.sh && make test`
Expected: PASS, `-- 9 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add .gitignore upstream.pin config/env.example config/settings.example.json \
    scripts/lib/config.sh tests/ Makefile
git commit -m "feat: scaffolding and config resolution with precedence tests"
```

---

### Task 2: Settings library (create + check)

**Files:**
- Create: `scripts/lib/settings.sh`, `tests/test-settings.sh`
- Test: `tests/test-settings.sh`

**Interfaces:**
- Consumes: `REPO_DIR` from Task 1's `scripts/lib/config.sh`
- Produces:
  - `create_settings <target-path>` — copies `config/settings.example.json` (override dir via `SETTINGS_TEMPLATE`), fills secrets from env vars `COUCHDB_URI`, `COUCHDB_DBNAME`, `COUCHDB_USER`, `COUCHDB_PASSWORD`, `E2E_PASSPHRASE` (→ `passphrase`), `OBFUSCATE_PASSPHRASE` (→ `obfuscatePassphrase`), sets `isConfigured: true`, mode `0600`
  - `check_settings <path> [--allow-plaintext]` — exits non-zero (hard) unless `isConfigured` and `usePathObfuscation` are `true`; `encrypt: false` is hard-fail unless `--allow-plaintext` (then warning to stderr)

- [ ] **Step 1: Write the failing test**

Create `tests/test-settings.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/../scripts/lib/config.sh"
source "$SCRIPT_DIR/../scripts/lib/settings.sh"

target="$TEST_TMP/.livesync/settings.json"

# 1. create_settings fills env secrets, sets isConfigured, keeps E2E+obfuscation on
COUCHDB_URI="http://127.0.0.1:15984" \
COUCHDB_DBNAME="testdb" \
COUCHDB_USER="admin" \
COUCHDB_PASSWORD="testpass-e2e" \
E2E_PASSPHRASE="e2e-secret" \
OBFUSCATE_PASSPHRASE="obf-secret" \
create_settings "$target"

T="$target" assert_exit_code 0 node -e '
    const s = JSON.parse(require("fs").readFileSync(process.env.T, "utf8"));
    const want = {couchDB_URI: "http://127.0.0.1:15984", couchDB_DBNAME: "testdb",
        couchDB_USER: "admin", couchDB_PASSWORD: "testpass-e2e",
        passphrase: "e2e-secret", obfuscatePassphrase: "obf-secret",
        isConfigured: true, encrypt: true, usePathObfuscation: true};
    for (const k in want) if (s[k] !== want[k]) { console.error("mismatch: " + k); process.exit(1); }
' && ok "create_settings fills secrets and flags"

# 2. Review Focus: settings file mode 0600
mode=$(stat -f '%Lp' "$target" 2>/dev/null || stat -c '%a' "$target")
assert_eq "$mode" "600" "settings file mode is 0600"

# 3. check_settings passes on a good file
assert_exit_code 0 check_settings "$target"
ok "check_settings passes good file"

# 4. Review Focus: obfuscation off -> hard fail (silent-desync guard)
sed 's/"usePathObfuscation": true/"usePathObfuscation": false/' "$target" > "$TEST_TMP/bad-obf.json"
assert_exit_code 1 check_settings "$TEST_TMP/bad-obf.json"
ok "check_settings fails when obfuscation off"

# 5. encrypt off -> hard fail; --allow-plaintext -> pass
sed 's/"encrypt": true/"encrypt": false/' "$target" > "$TEST_TMP/no-e2e.json"
assert_exit_code 1 check_settings "$TEST_TMP/no-e2e.json"
ok "check_settings fails when encrypt off"
assert_exit_code 0 check_settings "$TEST_TMP/no-e2e.json" --allow-plaintext
ok "check_settings allows plaintext with --allow-plaintext"

# 6. missing file -> fail
assert_exit_code 1 check_settings "$TEST_TMP/does-not-exist.json"
ok "check_settings fails on missing file"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-settings.sh`
Expected: FAIL — `scripts/lib/settings.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/settings.sh`:

```bash
#!/usr/bin/env bash
# Settings creation and sanity checks for livesync-headless.
set -euo pipefail

create_settings() {
    local target="$1"
    local template="${SETTINGS_TEMPLATE:-$REPO_DIR/config/settings.example.json}"
    if [[ ! -f "$template" ]]; then
        echo "Error: settings template not found: $template" >&2
        return 1
    fi
    mkdir -p "$(dirname "$target")"
    cp "$template" "$target"
    SETTINGS_TARGET="$target" node <<'NODE'
const fs = require("fs");
const s = JSON.parse(fs.readFileSync(process.env.SETTINGS_TARGET, "utf8"));
const env = process.env;
if (env.COUCHDB_URI) s.couchDB_URI = env.COUCHDB_URI;
if (env.COUCHDB_DBNAME) s.couchDB_DBNAME = env.COUCHDB_DBNAME;
if (env.COUCHDB_USER) s.couchDB_USER = env.COUCHDB_USER;
if (env.COUCHDB_PASSWORD) s.couchDB_PASSWORD = env.COUCHDB_PASSWORD;
if (env.E2E_PASSPHRASE) s.passphrase = env.E2E_PASSPHRASE;
if (env.OBFUSCATE_PASSPHRASE) s.obfuscatePassphrase = env.OBFUSCATE_PASSPHRASE;
s.isConfigured = true;
fs.writeFileSync(process.env.SETTINGS_TARGET, JSON.stringify(s, null, 4) + "\n");
NODE
    chmod 600 "$target"
    echo "Created $target"
}

check_settings() {
    local target="$1"; shift || true
    local allow_plaintext=0
    if [[ "${1:-}" == "--allow-plaintext" ]]; then allow_plaintext=1; fi
    if [[ ! -f "$target" ]]; then
        echo "FAIL: settings file missing: $target" >&2
        return 1
    fi
    SETTINGS_TARGET="$target" ALLOW_PLAINTEXT="$allow_plaintext" node <<'NODE'
const fs = require("fs");
const s = JSON.parse(fs.readFileSync(process.env.SETTINGS_TARGET, "utf8"));
let bad = false;
const fail = (m) => { console.error("FAIL: " + m); bad = true; };
if (s.isConfigured !== true) fail("isConfigured is not true");
if (s.usePathObfuscation !== true) fail("usePathObfuscation is not true (must match your other devices)");
if (s.encrypt !== true) {
    if (process.env.ALLOW_PLAINTEXT === "1") {
        console.error("WARN: encrypt is off (--allow-plaintext accepted)");
    } else {
        fail("encrypt is not true (pass --allow-plaintext to accept)");
    }
}
process.exit(bad ? 1 : 0);
NODE
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-settings.sh && make test`
Expected: PASS (`-- 6 passed, 0 failed`)

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/settings.sh tests/test-settings.sh
git commit -m "feat: settings create/check library with obfuscation and E2E guards"
```

---

### Task 3: bootstrap.sh — pinned clone, checkout, build

**Files:**
- Create: `scripts/bootstrap.sh`, `tests/test-bootstrap.sh`
- Test: `tests/test-bootstrap.sh`

**Interfaces:**
- Consumes: `resolve_config` (Task 1), `upstream.pin` content
- Produces: exit 0 with `$UPSTREAM_DIR` checked out at the pin, built (`src/apps/cli/dist/index.cjs` present unless `SKIP_BUILD=1`), and pin recorded in `$UPSTREAM_DIR/.livesync-headless-pin` (consumed by Task 6 `update.sh`). Env overrides: `UPSTREAM_REMOTE` (git URL; default `https://github.com/vrtmrz/obsidian-livesync`), `SKIP_BUILD=1` (tests; skips npm + dist assertion).

- [ ] **Step 1: Write the failing test**

Create `tests/test-bootstrap.sh` (uses a local git fixture — no network):

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Local "upstream" fixture repo with tag 9.9.9 and the files bootstrap checks
fixture="$TEST_TMP/upstream-remote"
mkdir -p "$fixture/src/apps/cli/deploy"
echo '{"name":"self-hosted-livesync-cli"}' > "$fixture/src/apps/cli/package.json"
echo '#!/usr/bin/env bash' > "$fixture/src/apps/cli/deploy/install.sh"
git -C "$fixture" init -q
git -C "$fixture" add -A
git -C "$fixture" -c user.email=t@t -c user.name=t commit -qm "fixture"
git -C "$fixture" tag 9.9.9

clone="$TEST_TMP/upstream-clone"

run_bootstrap() {
    UPSTREAM_REMOTE="$fixture" UPSTREAM_DIR="$clone" SKIP_BUILD=1 \
        REPO_DIR="$SCRIPT_DIR/.." PIN_OVERRIDE=9.9.9 \
        bash "$SCRIPT_DIR/../scripts/bootstrap.sh"
}

# 1. clones at pin and records it
run_bootstrap
assert_eq "$(git -C "$clone" describe --tags)" "9.9.9" "clone checked out at pinned tag"
assert_eq "$(cat "$clone/.livesync-headless-pin")" "9.9.9" "pin recorded"

# 2. idempotent second run
run_bootstrap
ok "second bootstrap succeeds"

# 3. Review Focus: refuses dirty upstream tree (modify a TRACKED file;
#    untracked files are tolerated because the pin record is untracked)
echo "local junk" >> "$clone/src/apps/cli/package.json"
assert_exit_code 1 run_bootstrap
ok "bootstrap refuses dirty clone"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-bootstrap.sh`
Expected: FAIL — `scripts/bootstrap.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `scripts/bootstrap.sh`:

```bash
#!/usr/bin/env bash
# Clone/update the pinned upstream obsidian-livesync and build the CLI.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
resolve_config "$@"

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-https://github.com/vrtmrz/obsidian-livesync}"
PIN="${PIN_OVERRIDE:-$(tr -d '[:space:]' < "$REPO_DIR/upstream.pin")}"

if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
    echo "[INFO] Cloning $UPSTREAM_REMOTE -> $UPSTREAM_DIR"
    mkdir -p "$(dirname "$UPSTREAM_DIR")"
    git clone "$UPSTREAM_REMOTE" "$UPSTREAM_DIR"
else
    echo "[INFO] Using existing clone at $UPSTREAM_DIR"
    git -C "$UPSTREAM_DIR" fetch --tags --force "$UPSTREAM_REMOTE" 'refs/tags/*:refs/tags/*'
    git -C "$UPSTREAM_DIR" fetch "$UPSTREAM_REMOTE"
fi

if [[ -n "$(git -C "$UPSTREAM_DIR" status --porcelain --untracked-files=no)" ]]; then
    # Tracked files must be pristine. Untracked files are tolerated because
    # bootstrap itself writes .livesync-headless-pin into this tree.
    echo "Error: $UPSTREAM_DIR has local modifications; refusing to proceed." >&2
    echo "       Commit/stash them or re-clone manually." >&2
    exit 1
fi

git -C "$UPSTREAM_DIR" checkout --quiet "$PIN"
echo "[INFO] Checked out $PIN"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    echo "[INFO] Building CLI (npm install + build)..."
    (cd "$UPSTREAM_DIR" && npm install --silent)
    (cd "$UPSTREAM_DIR/src/apps/cli" && npm run build)
    if [[ ! -f "$UPSTREAM_DIR/src/apps/cli/dist/index.cjs" ]]; then
        echo "Error: build output missing: $UPSTREAM_DIR/src/apps/cli/dist/index.cjs" >&2
        exit 1
    fi
else
    echo "[INFO] SKIP_BUILD=1, skipping npm build"
fi

echo "$PIN" > "$UPSTREAM_DIR/.livesync-headless-pin"
echo "[INFO] Bootstrap complete at pin $PIN"
```

```bash
chmod +x scripts/bootstrap.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-bootstrap.sh && make test`
Expected: PASS (`-- 3 passed, 0 failed`)

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.sh tests/test-bootstrap.sh
git commit -m "feat: bootstrap pinned upstream clone with dirty-tree guard"
```

---

### Task 4: install.sh — settings, preflight sync, upstream installer

**Files:**
- Create: `scripts/install.sh`, `tests/test-install.sh`
- Test: `tests/test-install.sh`

**Interfaces:**
- Consumes: `resolve_config` (Task 1), `create_settings` (Task 2), `scripts/bootstrap.sh` (Task 3)
- Produces: exit 0 after: settings exist at `$VAULT_DIR/.livesync/settings.json` (0600, `isConfigured: true`), preflight `sync` succeeded, and upstream `deploy/install.sh --user --vault <vault> [--interval N]` ran. Env overrides for tests: `LIVESYNC_CLI_CMD` (command prefix replacing `node <upstream>/src/apps/cli/dist/index.cjs`), `SKIP_BOOTSTRAP=1`, `UPSTREAM_REMOTE`/`SKIP_BUILD` pass through to bootstrap.

- [ ] **Step 1: Write the failing test**

Create `tests/test-install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Fixture upstream (clone from Task-3-style fixture) with stub installer that logs its args
fixture="$TEST_TMP/upstream-remote"
mkdir -p "$fixture/src/apps/cli/deploy"
echo '{}' > "$fixture/src/apps/cli/package.json"
cat > "$fixture/src/apps/cli/deploy/install.sh" <<'EOS'
#!/usr/bin/env bash
echo "INSTALLER_ARGS: $*" >> "$INSTALL_LOG"
EOS
chmod +x "$fixture/src/apps/cli/deploy/install.sh"
git -C "$fixture" init -q && git -C "$fixture" add -A
git -C "$fixture" -c user.email=t@t -c user.name=t commit -qm fixture
git -C "$fixture" tag 9.9.9

clone="$TEST_TMP/upstream-clone"
git -C "$fixture" clone -q "$fixture" "$clone"

vault="$TEST_TMP/vault"
cli_log="$TEST_TMP/cli.log"
export INSTALL_LOG="$TEST_TMP/installer.log"
: > "$INSTALL_LOG"

run_install() {
    VAULT_DIR="$vault" UPSTREAM_DIR="$clone" REPO_DIR="$SCRIPT_DIR/.." \
    SKIP_BOOTSTRAP=1 LIVESYNC_CLI_CMD="bash $TEST_TMP/stub-cli.sh" \
        bash "$SCRIPT_DIR/../scripts/install.sh"
}

cat > "$TEST_TMP/stub-cli.sh" <<'EOS'
#!/usr/bin/env bash
echo "cli: $*" >> "${CLI_LOG:?}"
exit "${CLI_EXIT:-0}"
EOS

# 1. happy path: settings created, preflight ran, installer invoked with --vault
export CLI_LOG="$cli_log"
run_install
[[ -f "$vault/.livesync/settings.json" ]] && ok "settings created" || fail "settings created"
assert_file_contains "$cli_log" "sync" "preflight sync executed"
assert_file_contains "$INSTALL_LOG" "--user --vault $vault" "installer called with --user --vault"
T="$vault/.livesync/settings.json" assert_exit_code 0 node -e '
    const s = JSON.parse(require("fs").readFileSync(process.env.T, "utf8"));
    process.exit(s.isConfigured === true ? 0 : 1);
' && ok "isConfigured set to true"

# 2. installer NOT called again when settings already exist (idempotent config step)
before=$(grep -c INSTALLER_ARGS "$INSTALL_LOG" || true)
run_install
after=$(grep -c INSTALLER_ARGS "$INSTALL_LOG" || true)
assert_eq "$after" "$((before + 1))" "installer ran exactly once more"
[[ "$(grep -c 'cli: .* sync' "$cli_log")" -ge 2 ]] && ok "preflight re-runs each install"

# 3. Review Focus: preflight sync failure aborts before installer
#    (rc captured with || so `set -e` does not kill the test)
: > "$INSTALL_LOG"
rc=0
CLI_EXIT=1 run_install || rc=$?
assert_eq "$rc" "1" "install exits non-zero on preflight failure"
if [[ -s "$INSTALL_LOG" ]]; then fail "installer must not run after failed preflight"; else ok "installer skipped after failed preflight"; fi

# 4. missing secrets in non-interactive mode -> abort with clear error
rm -rf "$vault/.livesync"
out=$(VAULT_DIR="$vault" UPSTREAM_DIR="$clone" REPO_DIR="$SCRIPT_DIR/.." \
    SKIP_BOOTSTRAP=1 LIVESYNC_CLI_CMD="bash $TEST_TMP/stub-cli.sh" \
    bash "$SCRIPT_DIR/../scripts/install.sh" </dev/null 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "aborts without secrets in non-tty mode"
assert_file_contains <(echo "$out") "COUCHDB_USER" "error names the first missing variable"

finish
```

Note: `assert_file_contains <(echo "$out")` works because the helper greps a path argument; process substitution supplies one.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-install.sh`
Expected: FAIL — `scripts/install.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `scripts/install.sh`:

```bash
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
    require_secret OBFUSCATE_PASSPHRASE "Obfuscation passphrase (must match your other devices)"
    create_settings "$settings"
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
```

```bash
chmod +x scripts/install.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-install.sh && make test`
Expected: PASS (`-- 7 passed, 0 failed`)

- [ ] **Step 5: Commit**

```bash
git add scripts/install.sh tests/test-install.sh
git commit -m "feat: install with secret prompts, preflight sync gate, upstream installer"
```

---

### Task 5: verify.sh — healthcheck

**Files:**
- Create: `scripts/verify.sh`, `tests/test-verify.sh`
- Test: `tests/test-verify.sh`

**Interfaces:**
- Consumes: `resolve_config` (Task 1), `check_settings` (Task 2)
- Produces: exit 0 only when all hard checks pass. Hard: service active, settings sane (`check_settings`, honouring `ALLOW_PLAINTEXT=1` env → `--allow-plaintext`), `ls` roundtrip. Warn: error lines in recent journal. Env overrides for tests: `SYSTEMCTL_CMD` (default `systemctl --user`), `JOURNALCTL_CMD` (default `journalctl --user -u livesync-cli -n 50 --no-pager`), `LIVESYNC_CLI_CMD`.

- [ ] **Step 1: Write the failing test**

Create `tests/test-verify.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/../scripts/lib/config.sh"
source "$SCRIPT_DIR/../scripts/lib/settings.sh"

vault="$TEST_TMP/vault"
mkdir -p "$vault"
COUCHDB_USER=u COUCHDB_PASSWORD=p E2E_PASSPHRASE=e OBFUSCATE_PASSPHRASE=o \
    create_settings "$vault/.livesync/settings.json"

stub_dir="$TEST_TMP/stubs"
mkdir -p "$stub_dir"

run_verify() {
    VAULT_DIR="$vault" REPO_DIR="$SCRIPT_DIR/.." \
    SYSTEMCTL_CMD="bash $stub_dir/systemctl.sh" \
    JOURNALCTL_CMD="bash $stub_dir/journalctl.sh" \
    LIVESYNC_CLI_CMD="bash $stub_dir/cli.sh" \
        bash "$SCRIPT_DIR/../scripts/verify.sh"
}

# systemctl stub: active unless SERVICE_INACTIVE=1
cat > "$stub_dir/systemctl.sh" <<'EOS'
#!/usr/bin/env bash
[[ "${SERVICE_INACTIVE:-0}" == "1" ]] && exit 1
[[ "$1 $2" == "is-active livesync-cli" ]] || { echo "unexpected systemctl args: $*" >&2; exit 2; }
exit 0
EOS
cat > "$stub_dir/journalctl.sh" <<'EOS'
#!/usr/bin/env bash
[[ "${JOURNAL_ERRORS:-0}" == "1" ]] && echo "Sep 23 10:00:00 host livesync-cli[1]: some error happened"
exit 0
EOS
cat > "$stub_dir/cli.sh" <<'EOS'
#!/usr/bin/env bash
[[ "${CLI_FAIL:-0}" == "1" ]] && exit 1
[[ "$2" == "ls" ]] || { echo "unexpected cli args: $*" >&2; exit 2; }
exit 0
EOS
chmod +x "$stub_dir"/*.sh

# 1. all healthy -> exit 0
assert_exit_code 0 run_verify
ok "verify passes when healthy"

# 2. service inactive -> non-zero
export SERVICE_INACTIVE=1
rc=0; run_verify || rc=$?
assert_eq "$rc" "1" "verify fails when service inactive"
unset SERVICE_INACTIVE

# 3. Review Focus: obfuscation off -> non-zero
sed -i.bak 's/"usePathObfuscation": true/"usePathObfuscation": false/' "$vault/.livesync/settings.json"
assert_exit_code 1 run_verify
ok "verify fails when obfuscation off"
sed -i.bak 's/"usePathObfuscation": false/"usePathObfuscation": true/' "$vault/.livesync/settings.json"

# 4. cli ls failing -> non-zero
export CLI_FAIL=1
rc=0; run_verify || rc=$?
assert_eq "$rc" "1" "verify fails when cli ls fails"
unset CLI_FAIL

# 5. journal errors -> warning only, still exit 0
export JOURNAL_ERRORS=1
assert_exit_code 0 run_verify
ok "journal errors are warn-only"
unset JOURNAL_ERRORS

# 6. ALLOW_PLAINTEXT=1 downgrades encrypt check
sed -i.bak 's/"encrypt": true/"encrypt": false/' "$vault/.livesync/settings.json"
assert_exit_code 1 run_verify
ok "encrypt off fails by default"
export ALLOW_PLAINTEXT=1
assert_exit_code 0 run_verify
ok "encrypt off passes with ALLOW_PLAINTEXT=1"
unset ALLOW_PLAINTEXT

finish
```

macOS note: `sed -i.bak ... && rm -f *.bak` — the `.bak` suffix files are inside `$TEST_TMP`, which is cleaned up by the trap; no extra handling needed.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-verify.sh`
Expected: FAIL — `scripts/verify.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `scripts/verify.sh`:

```bash
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
```

```bash
chmod +x scripts/verify.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-verify.sh && make test`
Expected: PASS (`-- 7 passed, 0 failed`)

- [ ] **Step 5: Commit**

```bash
git add scripts/verify.sh tests/test-verify.sh
git commit -m "feat: verify healthcheck with hard/warn checks and plaintext downgrade"
```

---

### Task 6: update.sh — explicit pin bump workflow

**Files:**
- Create: `scripts/update.sh`, `tests/test-update.sh`
- Test: `tests/test-update.sh`

**Interfaces:**
- Consumes: `resolve_config` (Task 1), `$UPSTREAM_DIR/.livesync-headless-pin` (Task 3), `scripts/install.sh` (Task 4), `scripts/verify.sh` (Task 5), `upstream.pin`
- Produces: exit 0 after reinstall+verify at the new pin. Aborts (exit 1) when recorded pin equals `upstream.pin`. Env override for tests: `SKIP_INSTALL=1`, `SKIP_VERIFY=1` (call real install/verify otherwise), plus everything bootstrap/install accept.

- [ ] **Step 1: Write the failing test**

Create `tests/test-update.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Fixture upstream with two tags; clone sitting at old pin
fixture="$TEST_TMP/upstream-remote"
mkdir -p "$fixture/src/apps/cli/deploy"
echo '{}' > "$fixture/src/apps/cli/package.json"
echo '#!/usr/bin/env bash' > "$fixture/src/apps/cli/deploy/install.sh"
git -C "$fixture" init -q && git -C "$fixture" add -A
git -C "$fixture" -c user.email=t@t -c user.name=t commit -qm v1
git -C "$fixture" tag 9.9.8
echo '{"v":2}' > "$fixture/src/apps/cli/package.json"
git -C "$fixture" add -A && git -C "$fixture" -c user.email=t@t -c user.name=t commit -qm v2
git -C "$fixture" tag 9.9.9

clone="$TEST_TMP/upstream-clone"
git -C "$fixture" clone -q "$fixture" "$clone"
git -C "$clone" checkout -q 9.9.8
echo "9.9.8" > "$clone/.livesync-headless-pin"

repo="$TEST_TMP/repo"   # mini repo holding only upstream.pin
mkdir -p "$repo/scripts" "$repo/scripts/lib"
cp "$SCRIPT_DIR/../scripts/lib/config.sh" "$repo/scripts/lib/"
echo "9.9.9" > "$repo/upstream.pin"

run_update() {
    VAULT_DIR="$TEST_TMP/vault" UPSTREAM_DIR="$clone" REPO_DIR="$repo" \
    UPSTREAM_REMOTE="$fixture" SKIP_BUILD=1 SKIP_INSTALL=1 SKIP_VERIFY=1 \
        bash "$SCRIPT_DIR/../scripts/update.sh"
}

# 1. pin unchanged -> abort
echo "9.9.8" > "$repo/upstream.pin"
assert_exit_code 1 run_update
ok "update refuses when pin unchanged"
echo "9.9.9" > "$repo/upstream.pin"

# 2. pin changed -> checkout, record, succeed
assert_exit_code 0 run_update
assert_eq "$(git -C "$clone" describe --tags)" "9.9.9" "clone moved to new pin"
assert_eq "$(cat "$clone/.livesync-headless-pin")" "9.9.9" "new pin recorded"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-update.sh`
Expected: FAIL — `scripts/update.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `scripts/update.sh`:

```bash
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
```

(`UPSTREAM_REMOTE` and `SKIP_BUILD` are environment variables and flow into `bootstrap.sh` automatically.)

```bash
chmod +x scripts/update.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-update.sh && make test`
Expected: PASS (`-- 3 passed, 0 failed`)

- [ ] **Step 5: Commit**

```bash
git add scripts/update.sh tests/test-update.sh
git commit -m "feat: update workflow with pin-diff guard, reinstall and verify"
```

---

### Task 7: Makefile targets

**Files:**
- Modify: `Makefile`
- Test: `tests/test-makefile.sh`

**Interfaces:**
- Consumes: all scripts (Tasks 3–6)
- Produces: targets `bootstrap`, `install`, `update`, `status`, `verify`, `test`, `test-e2e-local`; each target forwards to the corresponding script (env vars pass through: `make install VAULT_DIR=/path`)

- [ ] **Step 1: Write the failing test**

Create `tests/test-makefile.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

makefile="$SCRIPT_DIR/../Makefile"

# 1. all targets exist
for t in bootstrap install update status verify test test-e2e-local; do
    assert_file_contains "$makefile" "$t:" "Makefile has target: $t"
done

# 2. .PHONY line present (so targets always run)
assert_file_contains "$makefile" ".PHONY:" "Makefile marks targets phony"

# 3. targets forward to scripts (spot-check two)
assert_file_contains "$makefile" "scripts/bootstrap.sh" "bootstrap target runs script"
assert_file_contains "$makefile" "scripts/verify.sh" "verify target runs script"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-makefile.sh`
Expected: FAIL — missing targets (`update:` etc. not in Makefile)

- [ ] **Step 3: Write minimal implementation**

Replace `Makefile` content with:

```make
.PHONY: bootstrap install update status verify test test-e2e-local

bootstrap:
	@bash scripts/bootstrap.sh $(ARGS)

install:
	@bash scripts/install.sh $(ARGS)

update:
	@bash scripts/update.sh $(ARGS)

status:
	@systemctl --user status livesync-cli --no-pager || true
	@journalctl --user -u livesync-cli -n 50 --no-pager || true

verify:
	@bash scripts/verify.sh $(ARGS)

test:
	@bash tests/run-all.sh

test-e2e-local:
	@bash scripts/test-e2e-local.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-makefile.sh && make test`
Expected: PASS (`-- 3 passed, 0 failed`)

- [ ] **Step 5: Commit**

```bash
git add Makefile tests/test-makefile.sh
git commit -m "feat: Makefile targets for all lifecycle operations"
```

---

### Task 8: Local e2e test (Docker CouchDB, two vaults)

**Files:**
- Create: `scripts/test-e2e-local.sh`
- Test: manual/automated by itself (`make test-e2e-local`); skips cleanly without Docker

**Interfaces:**
- Consumes: built CLI at `$UPSTREAM_DIR/src/apps/cli/dist/index.cjs` (run `make bootstrap` first), Docker with a CouchDB 3 image
- Produces: exit 0 = bidirectional sync proven locally (E2E + obfuscation on); exit 0 with `SKIP` message when Docker unavailable; non-zero on real failure

- [ ] **Step 1: Write the failing test / script**

Create `scripts/test-e2e-local.sh` (this script *is* the test):

```bash
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/livesync-e2e.XXXXXX")"
cleanup() {
    [[ -n "${DAEMON_PID:-}" ]] && kill "$DAEMON_PID" 2>/dev/null || true
    docker rm -f "$COUCH_NAME" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "[INFO] Starting CouchDB container..."
docker run -d --rm --name "$COUCH_NAME" -p "$COUCH_PORT:5984" \
    -e COUCHDB_USER=admin -e COUCHDB_PASSWORD=testpass-e2e couchdb:3 >/dev/null

echo "[INFO] Waiting for CouchDB..."
for i in $(seq 1 60); do
    if curl -sf "http://admin:testpass-e2e@127.0.0.1:$COUCH_PORT/" >/dev/null 2>&1; then break; fi
    sleep 1
done
curl -sf -X POST "http://admin:testpass-e2e@127.0.0.1:$COUCH_PORT/_cluster_setup" \
    -H 'Content-Type: application/json' -d '{"action":"enable_single_node"}' >/dev/null \
    || { echo "FAIL: could not initialise CouchDB single node" >&2; exit 1; }
curl -sf -X PUT "http://admin:testpass-e2e@127.0.0.1:$COUCH_PORT/obsidian-livesync-e2e" >/dev/null \
    || { echo "FAIL: could not create test database" >&2; exit 1; }

mk_vault() { # $1 = dir
    mkdir -p "$1/.livesync"
    cat > "$1/.livesync/settings.json" <<EOF
{
    "couchDB_URI": "http://127.0.0.1:$COUCH_PORT",
    "couchDB_DBNAME": "obsidian-livesync-e2e",
    "couchDB_USER": "admin",
    "couchDB_PASSWORD": "testpass-e2e",
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
```

```bash
chmod +x scripts/test-e2e-local.sh
```

- [ ] **Step 2: Run to verify behaviour**

Run: `bash scripts/test-e2e-local.sh`
Expected: either `SKIP: Docker not available...` (exit 0) or, with Docker: `PASS: bidirectional sync verified locally (E2E + obfuscation on)`. A real failure exits non-zero. (Requires prior `make bootstrap` for the built CLI.)

- [ ] **Step 3: Commit**

```bash
git add scripts/test-e2e-local.sh
git commit -m "feat: local e2e test with throwaway CouchDB and two vaults"
```

---

### Task 9: README runbook

**Files:**
- Create: `README.md`
- Test: none (documentation; verified by review against spec §8)

**Interfaces:**
- Consumes: everything above
- Produces: operator documentation

- [ ] **Step 1: Write README.md**

```markdown
# livesync-headless

Headless, live, bidirectional sync between an Obsidian vault on this server and
a remote CouchDB — powered by [obsidian-livesync](https://github.com/vrtmrz/obsidian-livesync)'s
own CLI (`self-hosted-livesync-cli`), pinned and wrapped by this repo.

## Requirements

- Linux server with systemd, Node.js >= 22, git
- A CouchDB reachable over HTTPS (remote is fine)
- On your other devices: obsidian-livesync already configured with E2E encryption
  and Obfuscate Properties enabled

## Quick start

    make install                    # interactive: prompts for secrets
    # or fully scripted:
    COUCHDB_URI=https://couch.example.com:5984 \
    COUCHDB_DBNAME=obsidian-livesync \
    COUCHDB_USER=... COUCHDB_PASSWORD=... \
    E2E_PASSPHRASE=... OBFUSCATE_PASSPHRASE=... \
        make install VAULT_DIR=/srv/vault

    make verify                     # healthcheck

## Where things live

| Path | What |
| --- | --- |
| `~/vault` (default, configurable) | the vault - actual markdown files |
| `~/vault/.livesync/settings.json` | secrets + config (0600, never committed) |
| `~/opt/obsidian-livesync` | pinned upstream clone + build tree |
| `~/.local/bin/livesync-cli` | installed CLI (upstream installer manages this) |
| `~/.config/systemd/user/livesync-cli.service` | systemd user unit |

Vault path resolution (highest wins): `--vault` flag, `VAULT_DIR` env,
`config/env.local` (copy from `config/env.example`), default `~/vault`.

## CRITICAL: passphrases must match your devices

The E2E passphrase and the obfuscation passphrase MUST equal the values your
other devices use. The obfuscation passphrase is baked into every document ID
in the database - a mismatched value does not error out, it silently desyncs.
Both are stored only in the gitignored `settings.json`.

## Sync behaviour

- Default: LiveSync mode - CouchDB `_changes` feed (sub-second remote -> local),
  chokidar file watching (instant local -> remote).
- Behind a proxy that kills long-lived connections? Set `SYNC_INTERVAL=30`
  (seconds) in `config/env.local` and re-run `make install`.

## Daily operations

    make status      # service status + last 50 journal lines
    make verify      # healthcheck (cron-friendly)

## Recovery runbook

- **Service down**: systemd restarts on failure (`Restart=on-failure`).
  `make status` first; journal tail included.
- **Locked remote / rebuild needed**:
  `livesync-cli ~/vault unlock-remote`, `mark-resolved`, `remote-status`
- **Conflicted file** (skipped by mirror, never destructively merged):
  `livesync-cli ~/vault info notes/foo.md` then
  `livesync-cli ~/vault resolve notes/foo.md <rev>`
- **Deleting files**: deletions must go through
  `livesync-cli ~/vault rm notes/foo.md` - `mirror` intentionally restores
  DB-only files; removing a file on disk alone makes it come back.
- **Plaintext DB (no E2E)**: discouraged; if unavoidable,
  `ALLOW_PLAINTEXT=1 make verify`.

## Updates (always explicit)

    # 1. Edit upstream.pin to the target tag (e.g. 1.1.0)
    # 2. Reinstall and verify:
    make update

Never automatic. Vault files and settings are untouched by updates.

## Tests

    make test              # unit tests (no network)
    make test-e2e-local    # throwaway CouchDB via Docker; SKIPs without Docker
```

- [ ] **Step 2: Verify docs targets work**

Run: `make test && make status`
Expected: unit tests pass; status shows `systemctl: Unit livesync-cli.service could not be found` (expected on a fresh machine) without failing the make target.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: operator runbook for install, recovery, updates"
```

---

## Final verification

- [ ] `make test` — all unit suites green
- [ ] `bash scripts/verify.sh` — expected to fail on an unconfigured machine with clear messages (service inactive, settings missing) — confirms hard checks fire
- [ ] `git log --oneline` — one commit per task
