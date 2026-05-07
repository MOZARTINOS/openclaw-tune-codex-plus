#!/usr/bin/env bash
# Preflight checks. Exits non-zero with a fix list on any blocker.
# Usage: ./preflight.sh <config.json>

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_bins jq node ssh scp
load_config "${1:?Usage: preflight.sh <config.json>}"

# Now CONTAINER and REMOTE are validated. Quote them when interpolating into shells.
CONTAINER_Q=$(printf %q "$CONTAINER")

ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
fail() { echo "  ✗ $*" >&2; FAILED=1; }
FAILED=0

echo "[1/8] Local tools"
ok "jq node ssh scp present"

echo "[2/8] Remote reachable"
if [ -z "$REMOTE" ]; then
    ok "local mode (no SSH)"
else
    if ssh_exec "echo ok" 2>/dev/null | grep -q ok; then ok "SSH to $REMOTE works"
    else fail "cannot SSH to $REMOTE — fix keys/network first"; exit 1
    fi
fi

echo "[3/8] Container running"
if ssh_exec "docker ps --filter name=$CONTAINER_Q --format '{{.Status}}'" 2>/dev/null | grep -q "Up "; then
    ok "container '$CONTAINER' is running"
else
    fail "container '$CONTAINER' not running — start it first"; exit 1
fi

echo "[4/8] Remote dependencies inside container"
for bin in docker tar find jq cp chown; do
    if ssh_exec "command -v $(printf %q "$bin") >/dev/null 2>&1 && echo ok" 2>/dev/null | grep -q ok; then
        ok "remote: $bin"
    else
        fail "remote tool missing: $bin"
    fi
done

echo "[5/8] OpenClaw version >= 2026.4.22"
VERSION=$(ssh_exec "docker exec $CONTAINER_Q node -e 'try{const p=require(\"/app/package.json\");console.log(p.version||\"\")}catch(e){}'" 2>/dev/null | tr -d '\r' || true)
MIN_VERSION="2026.4.22"
if [ -z "$VERSION" ]; then
    warn "could not read OpenClaw version (assuming new enough)"
else
    # Pick the lower of (min, version) — if it's still min, version is >= min.
    LOWER=$(printf '%s\n%s\n' "$MIN_VERSION" "$VERSION" | sort -V | head -n1)
    if [ "$LOWER" = "$MIN_VERSION" ]; then
        ok "OpenClaw $VERSION (>= $MIN_VERSION)"
    else
        fail "OpenClaw $VERSION < $MIN_VERSION — upgrade first (image: alpine/openclaw:latest)"
    fi
fi

echo "[6/8] auth.json is in chatgpt mode"
AUTH_RAW=$(ssh_exec "docker exec $CONTAINER_Q cat /home/node/.openclaw/.codex/auth.json" 2>/dev/null || true)
AUTH_MODE=$(printf '%s' "$AUTH_RAW" | jq -r '.auth_mode // ""' 2>/dev/null || echo "")
case "$AUTH_MODE" in
    chatgpt) ok "auth_mode=chatgpt" ;;
    apikey)  fail "auth_mode=apikey — bot is on PAID per-token billing. Run 'refresh-auth codex' inside container to re-login via OAuth." ;;
    "")      fail "auth.json missing or unreadable — run Codex device-auth login first" ;;
    *)       fail "auth_mode='$AUTH_MODE' — expected 'chatgpt'" ;;
esac

echo "[7/8] OPENAI_API_KEY not in container env"
if ssh_exec "docker exec $CONTAINER_Q cat /proc/1/environ" 2>/dev/null | tr '\0' '\n' | grep -q '^OPENAI_API_KEY='; then
    fail "OPENAI_API_KEY is in container env — Codex CLI will overwrite auth.json to apikey on every restart. Remove from docker-compose / .env / start args."
else
    ok "OPENAI_API_KEY not present in process env"
fi

echo "[8/8] Codex CLI version >= 0.124.0"
CODEX_VER=$(ssh_exec "docker exec $CONTAINER_Q /home/node/.openclaw/.npm-global/bin/codex --version" 2>/dev/null | tr -d '\r' | awk '{print $NF}' || true)
MIN_CODEX="0.124.0"
if [ -z "$CODEX_VER" ]; then
    warn "could not read Codex CLI version"
else
    LOWER=$(printf '%s\n%s\n' "$MIN_CODEX" "$CODEX_VER" | sort -V | head -n1)
    if [ "$LOWER" = "$MIN_CODEX" ]; then
        ok "codex $CODEX_VER"
    else
        fail "codex $CODEX_VER < $MIN_CODEX — auto-refresh of OAuth tokens needs >= $MIN_CODEX"
    fi
fi

echo
if [ "$FAILED" = "1" ]; then
    echo "PREFLIGHT FAILED — fix the items marked ✗ above, then re-run." >&2
    exit 2
fi
echo "PREFLIGHT OK — ready to apply tune."
