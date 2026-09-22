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

    # Alternative: import the plugin's Setup URI (passphrase-protected).
    # Prompts for the URI passphrase, then enforces the same sanity checks:
    make import-uri URI='obsidian://setuplivesync?...'
    make install     # settings exist; preflight + service installation run

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

## Read-only mode (testing against a real database)

Test the whole setup against your real CouchDB with a hard guarantee that
nothing on the server can ever write to the remote database.

    # 1. Create a NON-ADMIN CouchDB member user (one-off, in CouchDB):
    #    e.g. put the user in the database members, not in _admin
    # 2. Turn the write guard ON (admin creds, prompted; blocks ALL non-admin writers):
    make readonly-on
    # 3. Install in read-only mode (uses config/env.local: READ_ONLY=1, SYNC_INTERVAL=60):
    READ_ONLY=1 make install VAULT_DIR=/srv/vault-test
    # 4. Pull once on demand, or let livesync-readonly.service keep it fresh:
    make pull-once
    # 5. When done testing:
    make readonly-off

Notes:
- The guard is a CouchDB design doc (`_design/__livesync_readonly_guard`) whose
  validator rejects every write from non-admin users. Reads and the _changes
  feed are unaffected.
- While the guard is ON, ALL non-admin writers are blocked - including your
  other devices if they use non-admin credentials. Turn it off when done.
- Read-only sync is additive: it never deletes local files (upstream mirror
  semantics restore DB-only files).

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
