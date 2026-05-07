#!/usr/bin/env bash
# Top-level installer. Orchestrates: prompt → preflight → render → deploy → verify.
#
# Usage:
#   ./install.sh                          # interactive (prompts), saves to ./config.json
#   ./install.sh --config friend.json     # use existing config (skips prompts)
#   ./install.sh --dry-run                # render locally only, no remote changes
#   ./install.sh --rollback <timestamp>   # restore from backup

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

CONFIG=""
DRY_RUN=0
ROLLBACK_TS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --config)   CONFIG="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --rollback) ROLLBACK_TS="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
openclaw-tune-codex-plus installer

  ./install.sh                          interactive (prompts → ./config.json)
  ./install.sh --config <path>          use existing config, no prompts
  ./install.sh --dry-run [--config X]   render locally only, no remote changes
  ./install.sh --rollback <timestamp>   restore from /root/openclaw-tune-backup-<ts>/
EOF
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

CONFIG="${CONFIG:-./config.json}"

# Rollback path
if [ -n "$ROLLBACK_TS" ]; then
    if [ ! -f "$CONFIG" ]; then
        echo "ERROR: rollback needs --config <path> (or default ./config.json)" >&2
        exit 1
    fi
    exec bash scripts/rollback.sh "$CONFIG" "$ROLLBACK_TS"
fi

# 1. Prompt or reuse config
if [ ! -f "$CONFIG" ]; then
    echo "=== Phase 1/5: collect config ==="
    bash scripts/prompt-config.sh "$CONFIG"
    echo
else
    echo "=== Phase 1/5: reuse config ($CONFIG) ==="
    bash scripts/prompt-config.sh --reuse "$CONFIG"
    echo
fi

# 2. Render locally (always)
echo "=== Phase 2/5: render bootstrap (local) ==="
OUT_DIR="./out"
rm -rf "$OUT_DIR"
node scripts/render-bootstrap.mjs "$CONFIG" "$OUT_DIR"
echo

if [ "$DRY_RUN" = "1" ]; then
    echo "DRY RUN — staged files in $OUT_DIR/. No remote changes made."
    echo "Re-run without --dry-run to apply."
    exit 0
fi

# 3. Preflight (remote)
echo "=== Phase 3/5: preflight (remote checks) ==="
bash scripts/preflight.sh "$CONFIG"
echo

# 4. Confirm before deploy
echo "=== Phase 4/5: deploy ==="
read -rp "Proceed with deploy? [y/N] " REPLY
case "${REPLY:-n}" in
    [Yy]*) ;;
    *) echo "Aborted by user."; exit 1 ;;
esac
bash scripts/deploy.sh "$CONFIG" "$OUT_DIR"
echo

# 5. Verify
echo "=== Phase 5/5: verify ==="
bash scripts/verify.sh "$CONFIG"
echo

echo "All phases complete."
echo "Send your bot a Telegram message to smoke-test."
echo "If something looks wrong: ./install.sh --rollback \$(cat $OUT_DIR/.last-backup-ts) --config $CONFIG"
