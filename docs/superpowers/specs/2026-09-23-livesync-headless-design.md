# livesync-headless — Design Spec

Date: 2026-09-23
Status: Approved design (pre-implementation)

## 1. Purpose

Run a headless, bidirectional, live-sync client for [obsidian-livesync](https://github.com/vrtmrz/obsidian-livesync) on a server: keep a plain-files Obsidian vault on the server continuously synchronized with a remote CouchDB, without Obsidian.

This repository is an **ops wrapper**, not a protocol implementation. Upstream's `self-hosted-livesync-cli` (shipped in the obsidian-livesync monorepo at `src/apps/cli/`) already provides the full sync core — chunking, E2E encryption, path obfuscation, conflict resolution, `_changes`-feed live sync — built on the same code as the plugin. We pin, build, deploy, configure, verify, and update it.

## 2. Requirements

### In scope (v1)

- Bidirectional live sync: remote CouchDB → vault files (`_changes` feed, sub-second) and vault files → CouchDB (chokidar file watching)
- Remote CouchDB over HTTPS, credentials in settings
- E2E encryption (same passphrase as other devices)
- Obfuscate Properties (`usePathObfuscation: true` + `obfuscatePassphrase`)
- Ordinary files only (notes + attachments); no Hidden File Sync
- Single vault
- systemd user service with restart-on-failure
- Reproducible installs pinned to an exact upstream tag
- Healthcheck script (cron-able)
- Update procedure (explicit, never automatic)
- **Read-only mode for testing**: pull remote → local files with a hard server-side guarantee that nothing is ever written to the remote DB (see §7a)

### Out of scope (v1)

- Object storage / S3 backends, P2P/WebRTC
- Hidden File Sync / Customization Sync
- REST/network `serve` mode (upstream "planned" only)
- Automatic upstream updates
- Any protocol code of our own

## 3. Key facts about upstream (verified against tag 1.0.30)

- `daemon` is the default command: initial mirror scan, then continuous two-way sync; exits cleanly on SIGINT/SIGTERM
- LiveSync mode (default) uses CouchDB `_changes`; `--interval N` switches to polling (fallback for proxies that break long-lived HTTP)
- `deploy/install.sh --user --vault <path> [--interval N]` builds the monorepo, installs bundle to `~/.local/lib/livesync-cli`, wrapper to `~/.local/bin/livesync-cli`, writes a user systemd unit, enables and starts it
- Settings: plugin-compatible JSON (`.livesync/settings.json` in the database directory), or applied from a plugin Setup URI via the `setup` command
- Path obfuscation is settings-driven, handled in the shared core (`src/common/utils.ts` `path2id()`); CLI tests run with it enabled
- CLI is not published to npm — deployment is always clone + build from the monorepo
- Recovery surface: `unlock-remote`, `mark-resolved`, `remote-status`, `info`, `resolve`, `rm`

## 4. Repository layout

```
livesync-headless/
├── upstream.pin              # exact upstream tag or commit, e.g. "1.0.30"
├── Makefile                  # bootstrap / install / update / status / verify targets
├── scripts/
│   ├── bootstrap.sh          # clone upstream at pin into UPSTREAM_DIR, npm install, build CLI
│   ├── install.sh            # configure settings (if missing) + run upstream deploy/install.sh
│   ├── update.sh             # re-read pin, fetch, rebuild, reinstall, restart service
│   ├── verify.sh             # healthcheck; non-zero exit on failure
│   ├── couchdb-readonly.sh   # on|off: install/remove CouchDB write-guard design doc (read-only mode)
│   ├── readonly-loop.sh      # pull-only sync+mirror loop used by the read-only service
│   └── import-uri.sh         # apply a passphrase-protected plugin Setup URI to the vault settings
├── config/
│   ├── settings.example.json # template; secrets replaced at install time
│   └── env.example           # server-specific paths & options, copied to config/env.local (gitignored)
└── README.md                 # runbook: setup, recovery, updates
```

## 5. Server layout

| Path | Contents |
| --- | --- |
| `~/vault` | the actual vault (markdown + attachments) |
| `~/vault/.livesync/` | PouchDB local database + `settings.json` (mode 0600) |
| `~/opt/obsidian-livesync` | pinned upstream clone (build tree) |
| `~/.local/lib/livesync-cli`, `~/.local/bin/livesync-cli` | installed CLI (managed by upstream installer) |
| `~/.config/systemd/user/livesync-cli.service` | systemd unit |

### Path configuration

The vault path is configurable — never hard-coded. Resolution order (highest wins):

1. `--vault <path>` flag on `bootstrap.sh` / `install.sh` / `update.sh` / `verify.sh`
2. `VAULT_DIR` environment variable
3. `config/env.local` (gitignored, server-specific; created from `config/env.example`)
4. Default: `~/vault`

`config/env.local` also carries `UPSTREAM_DIR` (default `~/opt/obsidian-livesync`) and optional `SYNC_INTERVAL` (seconds; unset = LiveSync `_changes` mode). All scripts `source` it if present; flags and environment always override.

## 6. Configuration & secrets

- `config/settings.example.json` contains non-secret defaults:

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

- `install.sh` fills secrets interactively (or from environment variables `COUCHDB_USER`, `COUCHDB_PASSWORD`, `E2E_PASSPHRASE`, `OBFUSCATE_PASSPHRASE`) into the server-local `settings.json`; that file is world-unreadable (0600) and never committed
- Alternative: apply a plugin Setup URI via `scripts/import-uri.sh "<uri>"` (`make import-uri URI=...`) — handles the URI's **passphrase protection**: passphrase from `SETUP_URI_PASSPHRASE` env (prompted on tty, hard error non-tty), piped to the CLI `setup` command on stdin; after import the script enforces `settings.json` mode 0600 and the same sanity checks as `verify.sh` (`isConfigured`, `usePathObfuscation`, `encrypt` unless `ALLOW_PLAINTEXT=1`). The URI carries E2E + obfuscation settings automatically.
- Constraints documented in README:
  - E2E passphrase and obfuscation passphrase **must match the other devices**; the obfuscation passphrase is baked into existing document IDs — a mismatched value produces broken sync, not an error
  - Changing either passphrase on all devices is a coordinated migration, out of scope for scripts

## 7. Scripts

### bootstrap.sh
1. Read `upstream.pin`
2. Clone upstream into `UPSTREAM_DIR` at that exact ref (clone if absent, `fetch + checkout` if present); refuse to proceed on dirty tree
3. `npm install` at repo root, `npm run build -w self-hosted-livesync-cli`
4. Assert `src/apps/cli/dist/index.cjs` exists

### install.sh
1. Run `bootstrap.sh` if `UPSTREAM_DIR` is missing
2. If `~/vault/.livesync/settings.json` missing: create from template, fill secrets (prompt or env), set `isConfigured: true`, `chmod 0600`, run one `sync` cycle to validate credentials before enabling the service
3. Run upstream `deploy/install.sh --user --vault "$VAULT_DIR"` (no `--interval` → LiveSync mode unless `SYNC_INTERVAL` set)
4. Report service status

### update.sh
1. Require the new pin to differ from the installed one; show pin diff
2. `bootstrap.sh` (fetch + checkout + rebuild)
3. Re-run upstream installer (restarts service); settings and vault untouched
4. Run `verify.sh`

### verify.sh
Checks; hard failures exit non-zero, warnings do not:
1. (hard) `systemctl --user is-active livesync-cli`
2. (hard) Settings sanity: `isConfigured: true`, `usePathObfuscation: true`; `encrypt: true` is hard unless `--allow-plaintext` is passed (then warn)
3. (hard) `livesync-cli "$VAULT_DIR" ls` returns successfully (daemon ↔ local DB alive)
4. (warn) Journal scan: errors in the last `journalctl --user -u livesync-cli` lines

### 7a. Read-only mode (testing)

Motivation: test the headless setup against the real CouchDB with a hard guarantee that nothing is ever written to the remote DB. Upstream cannot provide this client-side — its `sync`/`daemon` are bidirectional, and even pull-only replication attempts remote checkpoint writes. Therefore the guarantee is enforced **by CouchDB**.

**Write guard.** `scripts/couchdb-readonly.sh on` PUTs a design document `_design/__livesync_readonly_guard` into the target database:

```json
{
    "_id": "_design/__livesync_readonly_guard",
    "validate_doc_update": "function (newDoc, oldDoc, userCtx) { if (userCtx.roles.indexOf('_admin') !== -1) return; throw { forbidden: 'read-only guard active' }; }"
}
```

Every document write by a non-admin user is rejected with 403; reads and the `_changes` feed are unaffected (design-doc writes require admin and bypass the guard, so admins can still remove it). `off` deletes the guard. Both subcommands take admin credentials from `COUCHDB_ADMIN_USER` / `COUCHDB_ADMIN_PASSWORD` env (prompted if unset, never stored).

**Wrapper behaviour with `READ_ONLY=1`** (env or `config/env.local`):

- `install.sh` skips the preflight `sync` (it writes checkpoints) and instead validates credentials with a read-only HTTP GET on the database endpoint
- `install.sh` does NOT run the upstream installer/daemon (chokidar would push fs → DB); it writes its own `livesync-readonly.service` user unit running `scripts/readonly-loop.sh`
- `readonly-loop.sh`: `livesync-cli "$VAULT_DIR" sync` then `livesync-cli "$VAULT_DIR" mirror` every `SYNC_INTERVAL` seconds (default 60). Any push attempts are rejected server-side; pull continues (PouchDB treats failed checkpoint writes as non-fatal)
- The settings must use a **non-admin CouchDB user** while the guard is on; README documents creating one
- `make pull-once` runs one sync+mirror cycle on demand
- README warns: while the guard is on, ALL non-admin writes to that database are rejected — including from other devices using non-admin credentials; turn it off after testing (`make readonly-off`)
- Read-only mirror never deletes local files (upstream `mirror` semantics: DB-only files are restored); documented


## 8. Failure & recovery (README runbook)

- **Service down**: systemd restarts on failure; `make status` shows unit + journal tail
- **Locked / "Blob is not registered" style remote locks**: `unlock-remote`, `mark-resolved`, `remote-status` commands with examples
- **Conflicted file**: `info <path>` → `resolve <path> <rev>`; conflicted files are skipped by mirror, never auto-merged destructively on disk
- **Deleted file resurrection**: `mirror` intentionally restores DB-only files; deletions go through `rm` (documented, upstream behavior)
- **Bad proxy breaking `_changes`**: reinstall with `SYNC_INTERVAL=<seconds>`

## 9. Testing

- **Smoke (per-install)**: `verify.sh` (section 7)
- **Local e2e (optional, `make test-e2e-local`)**: throwaway CouchDB 3 container on localhost + two temp vaults; CLI daemon on vault A; write in A → appears in B's sync cycle and vice versa; asserts E2E + obfuscation settings on both sides. Never touches production CouchDB. Requires Docker locally; skipped with a clear message if unavailable.

## 10. Risks & mitigations

| Risk | Mitigation |
| --- | --- |
| Upstream CLI is young / behaviour changes between tags | Pin exact tag; updates are explicit + verified; vault is plain files (recoverable) and CouchDB retains history |
| Long-lived `_changes` blocked by intermediary | Polling fallback documented (`SYNC_INTERVAL`) |
| Mismatched E2E/obfuscation passphrase silently desyncs | README constraint section; `verify.sh` asserts flags on; pre-flight `sync` before enabling service |
| Secrets leakage | Secrets only in 0600 server-local settings; template has empty strings; `.gitignore` covers stray `settings.json` |
| `mirror` restores deleted files unexpectedly | Documented upstream behaviour; `rm` workflow in runbook |

## 11. Deliverables checklist

- [ ] `upstream.pin` (1.0.30)
- [ ] `Makefile` with `bootstrap`, `install`, `update`, `status`, `verify`, `test-e2e-local`, `pull-once`, `readonly-on`, `readonly-off`
- [ ] `scripts/bootstrap.sh`, `scripts/install.sh`, `scripts/update.sh`, `scripts/verify.sh`, `scripts/couchdb-readonly.sh`, `scripts/readonly-loop.sh`, `scripts/import-uri.sh`
- [ ] `config/settings.example.json`
- [ ] `config/env.example`
- [ ] `README.md` runbook
- [ ] `.gitignore` (settings.json, config/env.local, upstream clone, vault data)
