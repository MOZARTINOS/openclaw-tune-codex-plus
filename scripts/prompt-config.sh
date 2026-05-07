#!/usr/bin/env bash
# Interactive prompts → writes config.json. With --reuse, validates an existing config.
# Usage:
#   ./prompt-config.sh                         # writes ./config.json (interactive)
#   ./prompt-config.sh ~/my-bots/alex.json     # writes to that path
#   ./prompt-config.sh --reuse alex.json       # uses existing config (validate only)

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_bins jq

REUSE=0
if [ "${1:-}" = "--reuse" ]; then
    REUSE=1
    shift
fi

CONFIG_PATH="${1:-./config.json}"
mkdir -p "$(dirname "$CONFIG_PATH")"

if [ "$REUSE" = "1" ] && [ ! -f "$CONFIG_PATH" ]; then
    die "--reuse passed but $CONFIG_PATH does not exist"
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
    # Full schema validation via lib.sh — exits with clear error on bad fields.
    load_config "$CONFIG_PATH"
    echo "Using existing config: $CONFIG_PATH"
    printf '  remote=%s  container=%s\n  owner=%s tg=%s  tz=%s  lang=%s\n  bot=%s  heartbeat=%s\n' \
        "${REMOTE:-(local)}" "$CONTAINER" "$OWNER_NAME" "$OWNER_TG" "$TIMEZONE" "$LANGUAGE" "$BOT_NAME" "$HEARTBEAT_EVERY"
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

REMOTE_IN=$(prompt          "SSH target (user@host, leave empty for local install)" "")
CONTAINER_IN=$(prompt       "Container name" "openclaw")
OWNER_NAME_IN=$(prompt_required "Owner first name (display only)")
OWNER_TG_IN=$(prompt_required "Owner Telegram ID (numeric — see @userinfobot)")
TIMEZONE_IN=$(prompt        "Timezone (IANA, e.g. Europe/Berlin)" "UTC")
LANGUAGE_IN=$(prompt        "Reply language (e.g. en, ru, de)" "en")
BOT_NAME_IN=$(prompt_required "Bot name (in-character)")
BOT_EMOJI_IN=$(prompt       "Bot emoji" "🤖")
CHARACTER_BLURB_IN=$(prompt "Bot character — one line" "Pragmatic, concise, helpful.")
QUIET_HOURS_IN=$(prompt     "Quiet hours (no proactive messages)" "01:00-07:00")
HEARTBEAT_EVERY_IN=$(prompt "Heartbeat interval (e.g. 6h, 4h, 30m)" "6h")

# Validate everything before writing the file.
validate_ssh_target     "$REMOTE_IN"
validate_container_name "$CONTAINER_IN"
validate_telegram_id    "$OWNER_TG_IN"
validate_heartbeat      "$HEARTBEAT_EVERY_IN"

jq -n \
    --arg remote "$REMOTE_IN" \
    --arg container "$CONTAINER_IN" \
    --arg owner_name "$OWNER_NAME_IN" \
    --argjson owner_tg "$OWNER_TG_IN" \
    --arg timezone "$TIMEZONE_IN" \
    --arg language "$LANGUAGE_IN" \
    --arg bot_name "$BOT_NAME_IN" \
    --arg bot_emoji "$BOT_EMOJI_IN" \
    --arg character_blurb "$CHARACTER_BLURB_IN" \
    --arg quiet_hours "$QUIET_HOURS_IN" \
    --arg heartbeat "$HEARTBEAT_EVERY_IN" \
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
