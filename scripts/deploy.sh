#!/usr/bin/env bash
# Deploy staged bootstrap + Codex configs + chatgpt_limits.js to remote, restart container.
# Usage: ./deploy.sh <config.json> <out-dir>

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_bins jq node tar
load_config "${1:?Usage: deploy.sh <config.json> <out-dir>}"
OUT_DIR="${2:?Usage: deploy.sh <config.json> <out-dir>}"
[ -d "$OUT_DIR" ] || die "out-dir not found: $OUT_DIR"

CONTAINER_Q=$(printf %q "$CONTAINER")
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/openclaw-tune-backup-$TS"
BACKUP_DIR_Q=$(printf %q "$BACKUP_DIR")

echo "[deploy] backup → $BACKUP_DIR (fail-closed)"
ssh_exec "set -e; mkdir -p $BACKUP_DIR_Q && \
    cp -- /root/.openclaw/openclaw.json $BACKUP_DIR_Q/openclaw.json && \
    cp -a -- /root/.openclaw/workspace $BACKUP_DIR_Q/workspace && \
    cp -a -- /root/.openclaw/.codex $BACKUP_DIR_Q/.codex && \
    if [ -d /root/.openclaw/agents/main/agent/harness-auth ]; then \
        cp -a -- /root/.openclaw/agents/main/agent/harness-auth $BACKUP_DIR_Q/harness-auth; fi && \
    if [ -d /root/.openclaw/agents/main/agent/acp-auth ]; then \
        cp -a -- /root/.openclaw/agents/main/agent/acp-auth $BACKUP_DIR_Q/acp-auth; fi"
echo "  → use 'rollback.sh $1 $TS' to restore"

# Use a unique remote workdir to avoid collisions with concurrent installs.
REMOTE_TMP=$(ssh_exec "mktemp -d -t openclaw-tune.XXXXXX")
[ -n "$REMOTE_TMP" ] || die "could not create remote tmp dir"
REMOTE_TMP_Q=$(printf %q "$REMOTE_TMP")

echo "[deploy] uploading staged files → $REMOTE_TMP"
TARBALL=$(mktemp -t openclaw-tune.XXXXXX.tar.gz)
trap 'rm -f "$TARBALL"' EXIT
tar -czf "$TARBALL" -C "$OUT_DIR" .
scp_to "$TARBALL" "$REMOTE_TMP/payload.tar.gz"

echo "[deploy] writing bootstrap files (workspace/) — chown 1000:1000"
ssh_exec "set -e; \
    mkdir -p $REMOTE_TMP_Q/extract && \
    tar -xzf $REMOTE_TMP_Q/payload.tar.gz -C $REMOTE_TMP_Q/extract && \
    for f in AGENTS.md MEMORY.md TOOLS.md SOUL.md HEARTBEAT.md IDENTITY.md USER.md; do \
        [ -f $REMOTE_TMP_Q/extract/\$f ] && cp -- $REMOTE_TMP_Q/extract/\$f /root/.openclaw/workspace/\$f; \
    done && \
    chown 1000:1000 /root/.openclaw/workspace/*.md"

echo "[deploy] dropping chatgpt_limits.js into workspace/scripts/"
ssh_exec "set -e; \
    mkdir -p /root/.openclaw/workspace/scripts && \
    cp -- $REMOTE_TMP_Q/extract/chatgpt_limits.js /root/.openclaw/workspace/scripts/chatgpt_limits.js && \
    chown 1000:1000 /root/.openclaw/workspace/scripts/chatgpt_limits.js"

echo "[deploy] writing codex-config.toml to all account dirs (.codex + harness-auth + acp-auth)"
# Do the loop entirely on the remote side — no IFS-fragile $ACCT_DIRS.
# CONFIG_SRC is a single fixed path on the remote; pass it via env to the inner sh.
ssh_exec "set -e; \
    CONFIG_SRC=$REMOTE_TMP_Q/extract/codex-config.toml; \
    cp -- \"\$CONFIG_SRC\" /root/.openclaw/.codex/config.toml && \
    chown 1000:1000 /root/.openclaw/.codex/config.toml; \
    find /root/.openclaw/agents/main/agent/harness-auth/codex \
         /root/.openclaw/agents/main/agent/acp-auth/codex \
         -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        -exec sh -c 'cp -- \"\$1\" \"\$2/config.toml\" && chown 1000:1000 \"\$2/config.toml\"' sh \"\$CONFIG_SRC\" {} \\;"

echo "[deploy] patching openclaw.json (atomic via .new + mv)"
LOCAL_PATCHED=$(mktemp -t openclaw-json.XXXXXX)
trap 'rm -f "$TARBALL" "$LOCAL_PATCHED"' EXIT
ssh_exec "cat /root/.openclaw/openclaw.json" \
    | node "$SCRIPT_DIR/patch-openclaw-json.mjs" "$1" \
    > "$LOCAL_PATCHED"
scp_to "$LOCAL_PATCHED" "$REMOTE_TMP/openclaw.json.new"
ssh_exec "set -e; \
    if jq -e . $REMOTE_TMP_Q/openclaw.json.new >/dev/null 2>&1; then \
        mv -- $REMOTE_TMP_Q/openclaw.json.new /root/.openclaw/openclaw.json && \
        chown 1000:1000 /root/.openclaw/openclaw.json; \
    else \
        echo 'PATCH PRODUCED INVALID JSON — aborting' >&2; \
        rm -f $REMOTE_TMP_Q/openclaw.json.new; exit 3; \
    fi"

echo "[deploy] cleanup + restart container"
ssh_exec "rm -rf -- $REMOTE_TMP_Q && docker restart $CONTAINER_Q >/dev/null"

echo "[deploy] container restarted. Waiting 20s for warmup..."
sleep 20
echo "[deploy] DONE — backup at $BACKUP_DIR (TS=$TS)"
echo "$TS" > "${OUT_DIR}/.last-backup-ts"
