#!/usr/bin/env bash
# Deploy staged bootstrap + Codex configs + chatgpt_limits.js to remote, restart container.
# Usage: ./deploy.sh <config.json> <out-dir>
#
# Order of operations:
#   1. Backup current state on remote → /root/openclaw-tune-backup-<ts>/
#   2. tar + scp the staged files
#   3. Unpack into workspace, set ownership 1000:1000
#   4. Drop codex-config.toml into all 3 paths (.codex, harness-auth, acp-auth)
#   5. Patch openclaw.json (atomic: write .new, then mv)
#   6. Restart container

set -euo pipefail

CONFIG="${1:?Usage: deploy.sh <config.json> <out-dir>}"
OUT_DIR="${2:?Usage: deploy.sh <config.json> <out-dir>}"

REMOTE=$(jq -r '.remote.host // ""' "$CONFIG")
CONTAINER=$(jq -r '.remote.container // "openclaw"' "$CONFIG")
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/openclaw-tune-backup-$TS"

ssh_exec() {
    if [ -z "$REMOTE" ]; then bash -c "$*"
    else ssh "$REMOTE" "$@"; fi
}

scp_to() {
    local src="$1" dst="$2"
    if [ -z "$REMOTE" ]; then cp "$src" "$dst"
    else scp -q "$src" "$REMOTE:$dst"; fi
}

echo "[deploy] backup → $BACKUP_DIR"
ssh_exec "mkdir -p '$BACKUP_DIR' && cp /root/.openclaw/openclaw.json '$BACKUP_DIR/openclaw.json' && cp -r /root/.openclaw/workspace '$BACKUP_DIR/workspace' && cp -r /root/.openclaw/.codex '$BACKUP_DIR/.codex' || true"
echo "  → backup ID saved to ${BACKUP_DIR}"
echo "  → use 'rollback.sh $CONFIG $TS' to restore"

echo "[deploy] uploading staged files"
TARBALL="/tmp/openclaw-tune-$$.tar.gz"
tar -czf "$TARBALL" -C "$OUT_DIR" .
scp_to "$TARBALL" "/tmp/openclaw-tune.tar.gz"
rm -f "$TARBALL"

echo "[deploy] writing bootstrap files (workspace/) — chown 1000:1000"
ssh_exec "tar -xzf /tmp/openclaw-tune.tar.gz -C /tmp/openclaw-tune-extract/ --one-top-level=/tmp/openclaw-tune-extract 2>/dev/null || (mkdir -p /tmp/openclaw-tune-extract && tar -xzf /tmp/openclaw-tune.tar.gz -C /tmp/openclaw-tune-extract)"
# Move bootstrap files to workspace
ssh_exec "for f in AGENTS.md MEMORY.md TOOLS.md SOUL.md HEARTBEAT.md IDENTITY.md USER.md; do
    [ -f /tmp/openclaw-tune-extract/\$f ] && cp /tmp/openclaw-tune-extract/\$f /root/.openclaw/workspace/\$f
done && chown 1000:1000 /root/.openclaw/workspace/*.md"

echo "[deploy] dropping chatgpt_limits.js into workspace/scripts/"
ssh_exec "mkdir -p /root/.openclaw/workspace/scripts && cp /tmp/openclaw-tune-extract/chatgpt_limits.js /root/.openclaw/workspace/scripts/chatgpt_limits.js && chown 1000:1000 /root/.openclaw/workspace/scripts/chatgpt_limits.js"

echo "[deploy] writing codex-config.toml to 3 paths"
# Find harness-auth and acp-auth account dirs (they're keyed by hash)
ACCT_DIRS=$(ssh_exec "find /root/.openclaw/agents/main/agent/harness-auth/codex /root/.openclaw/agents/main/agent/acp-auth/codex -maxdepth 1 -mindepth 1 -type d 2>/dev/null" || echo "")
ssh_exec "cp /tmp/openclaw-tune-extract/codex-config.toml /root/.openclaw/.codex/config.toml && chown 1000:1000 /root/.openclaw/.codex/config.toml"
for d in $ACCT_DIRS; do
    ssh_exec "cp /tmp/openclaw-tune-extract/codex-config.toml '$d/config.toml' && chown 1000:1000 '$d/config.toml'"
    echo "  → $d/config.toml"
done

echo "[deploy] patching openclaw.json (atomic via .new + mv)"
ssh_exec "cat /root/.openclaw/openclaw.json" \
    | node "$(dirname "$0")/patch-openclaw-json.mjs" "$CONFIG" \
    > /tmp/openclaw.json.patched
scp_to /tmp/openclaw.json.patched /tmp/openclaw.json.new
rm -f /tmp/openclaw.json.patched
ssh_exec "if jq -e . /tmp/openclaw.json.new >/dev/null 2>&1; then mv /tmp/openclaw.json.new /root/.openclaw/openclaw.json && chown 1000:1000 /root/.openclaw/openclaw.json; else echo 'PATCH PRODUCED INVALID JSON — aborting'; rm /tmp/openclaw.json.new; exit 3; fi"

echo "[deploy] cleanup + restart container"
ssh_exec "rm -rf /tmp/openclaw-tune.tar.gz /tmp/openclaw-tune-extract && docker restart $CONTAINER >/dev/null"

echo "[deploy] container restarted. Waiting 20s for warmup..."
sleep 20
echo "[deploy] DONE — backup at $BACKUP_DIR (TS=$TS)"
echo "$TS" > "${OUT_DIR}/.last-backup-ts"
