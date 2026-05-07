#!/usr/bin/env bash
# Restore from a deploy.sh backup, then restart container.
# Usage: ./rollback.sh <config.json> <timestamp>
#   timestamp matches a directory at /root/openclaw-tune-backup-<ts>/

set -euo pipefail

CONFIG="${1:?Usage: rollback.sh <config.json> <timestamp>}"
TS="${2:?Usage: rollback.sh <config.json> <timestamp>}"

REMOTE=$(jq -r '.remote.host // ""' "$CONFIG")
CONTAINER=$(jq -r '.remote.container // "openclaw"' "$CONFIG")
BACKUP_DIR="/root/openclaw-tune-backup-$TS"

ssh_exec() {
    if [ -z "$REMOTE" ]; then bash -c "$*"
    else ssh "$REMOTE" "$@"; fi
}

if ! ssh_exec "test -d '$BACKUP_DIR'"; then
    echo "ERROR: backup not found at $BACKUP_DIR" >&2
    echo "Available backups:" >&2
    ssh_exec "ls -1d /root/openclaw-tune-backup-* 2>/dev/null" >&2 || true
    exit 1
fi

echo "[rollback] restoring from $BACKUP_DIR"
ssh_exec "cp '$BACKUP_DIR/openclaw.json' /root/.openclaw/openclaw.json && \
    rm -rf /root/.openclaw/workspace && cp -r '$BACKUP_DIR/workspace' /root/.openclaw/workspace && \
    rm -rf /root/.openclaw/.codex && cp -r '$BACKUP_DIR/.codex' /root/.openclaw/.codex && \
    chown -R 1000:1000 /root/.openclaw/openclaw.json /root/.openclaw/workspace /root/.openclaw/.codex"

echo "[rollback] restarting container"
ssh_exec "docker restart $CONTAINER >/dev/null"
sleep 15

echo "[rollback] DONE — pre-tune state restored. Backup dir kept at $BACKUP_DIR (delete manually if not needed)."
