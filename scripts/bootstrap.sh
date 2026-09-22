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
