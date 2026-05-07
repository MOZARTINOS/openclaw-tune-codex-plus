#!/usr/bin/env bash
# Preflight checks. Exits non-zero with a fix list on any blocker.
# Usage: ./preflight.sh <config.json>
#
# What it checks:
# 1. Required local tools (jq, node, ssh, scp)
# 2. Remote reachable (or local docker available)
# 3. Container is running and is OpenClaw
# 4. OpenClaw version >= 2026.4.22
# 5. auth.json is in chatgpt mode
# 6. OPENAI_API_KEY is NOT in container env
# 7. Codex CLI version >= 0.124.0

set -euo pipefail

CONFIG="${1:?Usage: preflight.sh <config.json>}"
[ -f "$CONFIG" ] || { echo "ERROR: config not found: $CONFIG" >&2; exit 1; }

REMOTE=$(jq -r '.remote.host // ""' "$CONFIG")
CONTAINER=$(jq -r '.remote.container // "openclaw"' "$CONFIG")

ssh_exec() {
    if [ -z "$REMOTE" ]; then
        bash -c "$*"
    else
        ssh -o ConnectTimeout=10 "$REMOTE" "$@"
    fi
}

ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
fail() { echo "  ✗ $*" >&2; FAILED=1; }

FAILED=0

echo "[1/7] Local tools"
for bin in jq node ssh scp; do
    if command -v "$bin" >/dev/null 2>&1; then ok "$bin"; else fail "$bin not found in PATH"; fi
done

echo "[2/7] Remote reachable"
if [ -z "$REMOTE" ]; then
    ok "local mode (no SSH)"
else
    if ssh_exec "echo ok" 2>/dev/null | grep -q ok; then ok "SSH to $REMOTE works"
    else fail "cannot SSH to $REMOTE — fix keys/network first"; exit 1
    fi
fi

echo "[3/7] Container running"
if ssh_exec "docker ps --filter name=$CONTAINER --format '{{.Status}}'" 2>/dev/null | grep -q "Up "; then
    ok "container '$CONTAINER' is running"
else
    fail "container '$CONTAINER' not running — start it first"
    exit 1
fi

echo "[4/7] OpenClaw version >= 2026.4.22"
VERSION=$(ssh_exec "docker exec $CONTAINER node -e 'try{const p=require(\"/app/package.json\");console.log(p.version||\"\")}catch(e){}' 2>/dev/null" | tr -d '\r' || true)
if [ -z "$VERSION" ]; then
    warn "could not read OpenClaw version (assuming new enough — proceed with caution)"
else
    # Compare YYYY.M.P as dotted; bash sort -V handles this
    if printf '%s\n2026.4.22\n' "$VERSION" | sort -V -C 2>/dev/null; then
        ok "OpenClaw $VERSION (>= 2026.4.22 required)"
    else
        # The "required min" comes second after our version, so if sort says they're already in order, our version is older
        if printf '2026.4.22\n%s\n' "$VERSION" | sort -V -C 2>/dev/null; then
            ok "OpenClaw $VERSION"
        else
            fail "OpenClaw $VERSION < 2026.4.22 — upgrade first (image: alpine/openclaw:latest)"
        fi
    fi
fi

echo "[5/7] auth.json is in chatgpt mode"
AUTH_MODE=$(ssh_exec "docker exec $CONTAINER cat /home/node/.openclaw/.codex/auth.json 2>/dev/null" | jq -r '.auth_mode // ""' 2>/dev/null || echo "")
case "$AUTH_MODE" in
    chatgpt) ok "auth_mode=chatgpt" ;;
    apikey)  fail "auth_mode=apikey — bot is on PAID per-token billing, NOT subscription. Run 'refresh-auth codex' inside container to re-login via OAuth." ;;
    "")      fail "auth.json missing or unreadable — run Codex device-auth login first" ;;
    *)       fail "auth_mode='$AUTH_MODE' — expected 'chatgpt'" ;;
esac

echo "[6/7] OPENAI_API_KEY not in container env"
if ssh_exec "docker exec $CONTAINER cat /proc/1/environ 2>/dev/null" | tr '\0' '\n' | grep -q '^OPENAI_API_KEY='; then
    fail "OPENAI_API_KEY is in container env — Codex CLI will overwrite auth.json to apikey on every restart. Remove from docker-compose / .env / start args."
else
    ok "OPENAI_API_KEY not present in process env"
fi

echo "[7/7] Codex CLI version >= 0.124.0"
CODEX_VER=$(ssh_exec "docker exec $CONTAINER /home/node/.openclaw/.npm-global/bin/codex --version 2>/dev/null" | tr -d '\r' | awk '{print $NF}' || echo "")
if [ -z "$CODEX_VER" ]; then
    warn "could not read Codex CLI version"
else
    if printf '0.124.0\n%s\n' "$CODEX_VER" | sort -V -C 2>/dev/null; then
        ok "codex $CODEX_VER"
    else
        fail "codex $CODEX_VER < 0.124.0 — auto-refresh of OAuth tokens needs >= 0.124.0"
    fi
fi

echo
if [ "$FAILED" = "1" ]; then
    echo "PREFLIGHT FAILED — fix the items marked ✗ above, then re-run." >&2
    exit 2
fi
echo "PREFLIGHT OK — ready to apply tune."
