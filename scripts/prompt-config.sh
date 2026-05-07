#!/usr/bin/env bash
# Interactive prompts → writes config.json with all fields the other scripts need.
# If a config file is passed as $1 and exists, this is a no-op (just validates and exits).
#
# Usage:
#   ./prompt-config.sh                         # writes ./config.json
#   ./prompt-config.sh ~/my-bots/alex.json     # writes to that path
#   ./prompt-config.sh --reuse alex.json       # uses existing config without prompts (validate only)

set -euo pipefail

REUSE=0
if [ "${1:-}" = "--reuse" ]; then
    REUSE=1
    shift
fi

CONFIG_PATH="${1:-./config.json}"
mkdir -p "$(dirname "$CONFIG_PATH")"

if [ "$REUSE" = "1" ] && [ ! -f "$CONFIG_PATH" ]; then
    echo "ERROR: --reuse passed but $CONFIG_PATH does not exist" >&2
    exit 1
fi

if [ -f "$CONFIG_PATH" ] && [ "$REUSE" = "0" ]; then
    echo "Config exists: $CONFIG_PATH"
    read -rp "Reuse it? [Y/n] " REPLY
    case "${REPLY:-y}" in
        [Yy]*|"") REUSE=1 ;;
        *) REUSE=0 ;;
    esac
fi

if [ "$REUSE" = "1" ]; then
    # Validate JSON, print summary, exit
    if ! jq -e . "$CONFIG_PATH" >/dev/null 2>&1; then
        echo "ERROR: $CONFIG_PATH is not valid JSON" >&2
        exit 1
    fi
    echo "Using existing config: $CONFIG_PATH"
    jq -r '"  remote=\(.remote.host // "(local)")  container=\(.remote.container // "openclaw")\n  owner=\(.owner.name) tg=\(.owner.telegramId)  tz=\(.owner.timezone)  lang=\(.owner.language)\n  bot=\(.bot.name)  heartbeat=\(.limits.heartbeatEvery // "6h")"' "$CONFIG_PATH"
    exit 0
fi

echo "openclaw-tune-codex-plus — interactive setup"
echo "Press Enter to accept the default in [brackets]."
echo

prompt() {
    local msg="$1" default="$2" var
    read -rp "$msg [$default]: " var
    echo "${var:-$default}"
}

prompt_required() {
    local msg="$1" var
    while :; do
        read -rp "$msg: " var
        if [ -n "$var" ]; then echo "$var"; return; fi
        echo "  (required — please answer)" >&2
    done
}

REMOTE=$(prompt          "SSH target (user@host, leave empty for local install)" "")
CONTAINER=$(prompt       "Container name" "openclaw")
OWNER_NAME=$(prompt_required "Owner first name (display only)")
OWNER_TG_ID=$(prompt_required "Owner Telegram ID (numeric — see @userinfobot)")
TIMEZONE=$(prompt        "Timezone (IANA, e.g. Europe/Berlin)" "UTC")
LANGUAGE=$(prompt        "Reply language (e.g. en, ru, de)" "en")
BOT_NAME=$(prompt_required "Bot name (in-character)")
BOT_EMOJI=$(prompt       "Bot emoji" "🤖")
CHARACTER_BLURB=$(prompt "Bot character — one line" "Pragmatic, concise, helpful.")
QUIET_HOURS=$(prompt     "Quiet hours (no proactive messages)" "01:00-07:00")
HEARTBEAT_EVERY=$(prompt "Heartbeat interval (cron-style, e.g. 6h, 4h, 30m)" "6h")

# Validate Telegram ID is numeric
if ! [[ "$OWNER_TG_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Telegram ID must be numeric, got: $OWNER_TG_ID" >&2
    exit 1
fi

# Build JSON via jq for safety (handles quoting in character blurb etc.)
jq -n \
    --arg remote "$REMOTE" \
    --arg container "$CONTAINER" \
    --arg owner_name "$OWNER_NAME" \
    --argjson owner_tg "$OWNER_TG_ID" \
    --arg timezone "$TIMEZONE" \
    --arg language "$LANGUAGE" \
    --arg bot_name "$BOT_NAME" \
    --arg bot_emoji "$BOT_EMOJI" \
    --arg character_blurb "$CHARACTER_BLURB" \
    --arg quiet_hours "$QUIET_HOURS" \
    --arg heartbeat "$HEARTBEAT_EVERY" \
    '{
        remote:   { host: $remote, container: $container },
        owner:    { name: $owner_name, telegramId: $owner_tg, timezone: $timezone, language: $language, quietHours: $quiet_hours },
        bot:      { name: $bot_name, emoji: $bot_emoji, characterBlurb: $character_blurb },
        limits:   { heartbeatEvery: $heartbeat },
        providers:{ geminiApiKeyEnv: "GEMINI_API_KEY" },
        options:  { installLimitsCommand: true, dryRun: false }
    }' > "$CONFIG_PATH"

chmod 600 "$CONFIG_PATH"
echo
echo "Saved: $CONFIG_PATH"
echo "Edit it directly if you need to change anything later."
