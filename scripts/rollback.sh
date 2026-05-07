#!/usr/bin/env bash
# Restore from a deploy.sh backup, then restart container.
# Usage: ./rollback.sh <config.json> <timestamp>
#   timestamp matches a directory at /root/openclaw-tune-backup-<ts>/

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_bins jq
load_config "${1:?Usage: rollback.sh <config.json> <timestamp>}"
TS="${2:?Usage: rollback.sh <config.json> <timestamp>}"
validate_timestamp "$TS"

CONTAINER_Q=$(printf %q "$CONTAINER")
BACKUP_DIR="/root/openclaw-tune-backup-$TS"
BACKUP_DIR_Q=$(printf %q "$BACKUP_DIR")

if ! ssh_exec "test -d $BACKUP_DIR_Q && echo ok" 2>/dev/null | grep -q ok; then
    echo "ERROR: backup not found at $BACKUP_DIR" >&2
    echo "Available backups:" >&2
    ssh_exec "ls -1d /root/openclaw-tune-backup-* 2>/dev/null" >&2 || true
    exit 1
fi

echo "[rollback] restoring from $BACKUP_DIR"
# Restore everything deploy.sh writes: openclaw.json, workspace, .codex, harness-auth, acp-auth.
# Each restore step is its own statement separated by ';' so 'set -e' aborts on
# any failure (rm OR cp). Inside '&&' chains, set -e is ignored for the LHS,
# which would silently skip cp on rm failure — never use '&&' here.
# chown is a separate per-path loop tolerant of missing optional paths.
ssh_exec "set -e; \
    cp -- $BACKUP_DIR_Q/openclaw.json /root/.openclaw/openclaw.json; \
    rm -rf /root/.openclaw/workspace; \
    cp -a -- $BACKUP_DIR_Q/workspace /root/.openclaw/workspace; \
    rm -rf /root/.openclaw/.codex; \
    cp -a -- $BACKUP_DIR_Q/.codex /root/.openclaw/.codex; \
    if [ -d $BACKUP_DIR_Q/harness-auth ]; then \
        rm -rf /root/.openclaw/agents/main/agent/harness-auth; \
        cp -a -- $BACKUP_DIR_Q/harness-auth /root/.openclaw/agents/main/agent/harness-auth; \
    fi; \
    if [ -d $BACKUP_DIR_Q/acp-auth ]; then \
        rm -rf /root/.openclaw/agents/main/agent/acp-auth; \
        cp -a -- $BACKUP_DIR_Q/acp-auth /root/.openclaw/agents/main/agent/acp-auth; \
    fi; \
    for p in /root/.openclaw/openclaw.json \
             /root/.openclaw/workspace \
             /root/.openclaw/.codex \
             /root/.openclaw/agents/main/agent/harness-auth \
             /root/.openclaw/agents/main/agent/acp-auth; do \
        if [ -e \"\$p\" ]; then chown -R 1000:1000 \"\$p\"; fi; \
    done"

echo "[rollback] restarting container"
ssh_exec "docker restart $CONTAINER_Q >/dev/null"
sleep 15

echo "[rollback] DONE — pre-tune state restored. Backup dir kept at $BACKUP_DIR (delete manually if not needed)."
