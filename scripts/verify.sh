#!/usr/bin/env bash
# Post-deploy verification. Refuses success if anything regressed.
# Usage: ./verify.sh <config.json>

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_bins jq
load_config "${1:?Usage: verify.sh <config.json>}"
CONTAINER_Q=$(printf %q "$CONTAINER")

ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; FAILED=1; }
FAILED=0

echo "[verify] auth_mode still chatgpt after restart"
AUTH_MODE=$(ssh_exec "docker exec $CONTAINER_Q cat /home/node/.openclaw/.codex/auth.json" 2>/dev/null | jq -r '.auth_mode // ""' 2>/dev/null || echo "")
if [ "$AUTH_MODE" = "chatgpt" ]; then ok "auth_mode=chatgpt"
else fail "auth_mode='$AUTH_MODE' — Codex CLI flipped to apikey on restart. Check OPENAI_API_KEY in container env."
fi

echo "[verify] OPENAI_API_KEY still absent from container env"
if ssh_exec "docker exec $CONTAINER_Q cat /proc/1/environ" 2>/dev/null | tr '\0' '\n' | grep -q '^OPENAI_API_KEY='; then
    fail "OPENAI_API_KEY appeared in process env — bot will silently switch to paid billing"
else
    ok "OPENAI_API_KEY not in env"
fi

echo "[verify] bootstrap byte counts (workspace/*.md)"
TOTAL=0
for f in AGENTS.md MEMORY.md TOOLS.md SOUL.md HEARTBEAT.md IDENTITY.md USER.md; do
    BYTES=$(ssh_exec "wc -c < /root/.openclaw/workspace/$(printf %q "$f")" 2>/dev/null | tr -d '\r ' || echo "0")
    if [ "$BYTES" = "0" ] || [ -z "$BYTES" ]; then
        fail "$f missing or empty"
        continue
    fi
    TOTAL=$((TOTAL + BYTES))
    if [ "$BYTES" -gt 12000 ]; then
        fail "$f is $BYTES bytes (> 12 KB engine limit, will be truncated)"
    else
        ok "$(printf '%-13s %5d bytes' "$f" "$BYTES")"
    fi
done
echo "  ─────────────────"
if [ "$TOTAL" -gt 60000 ]; then
    fail "TOTAL $TOTAL bytes (> 60 KB engine limit, last files will be truncated)"
else
    ok "$(printf 'TOTAL         %5d bytes  (limit 60000)' "$TOTAL")"
fi

echo "[verify] /limits probe (reads x-codex-* headers)"
PROBE_OUT=$(ssh_exec "docker exec -w /home/node/.openclaw/workspace $CONTAINER_Q node scripts/chatgpt_limits.js --fresh" 2>&1 || echo "FAIL")
if echo "$PROBE_OUT" | grep -q 'Codex OAuth usage'; then
    ok "probe succeeded"
    echo "$PROBE_OUT" | sed 's/^/    /'
else
    fail "probe failed:"
    echo "$PROBE_OUT" | sed 's/^/    /' >&2
fi

echo "[verify] tools.allow contains fs/exec tools"
ALLOW=$(ssh_exec "jq -r '.tools.allow | join(\",\")' /root/.openclaw/openclaw.json" 2>/dev/null || echo "")
for t in read write edit apply_patch exec process; do
    if echo ",$ALLOW," | grep -q ",$t,"; then ok "tools.allow has '$t'"
    else fail "tools.allow missing '$t' — chat will report 'no fs access'"
    fi
done

echo "[verify] channels.telegram.allowFrom contains owner"
ALLOWLIST=$(ssh_exec "jq -r '.channels.telegram.allowFrom | join(\",\")' /root/.openclaw/openclaw.json" 2>/dev/null || echo "")
if echo ",$ALLOWLIST," | grep -q ",$OWNER_TG,"; then ok "owner $OWNER_TG in allowFrom"
else fail "owner $OWNER_TG NOT in channels.telegram.allowFrom — bot will ignore your DMs"
fi

echo
if [ "$FAILED" = "1" ]; then
    echo "VERIFY FAILED — check items marked ✗ above. Consider rollback.sh." >&2
    exit 2
fi
echo "VERIFY OK — bot is tuned. Send it a Telegram message to smoke-test."
