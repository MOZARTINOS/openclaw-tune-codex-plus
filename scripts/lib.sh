#!/usr/bin/env bash
# Shared validation + helpers. Sourced by every other script.
# All exits via die() so callers see a clean error.

die() { echo "ERROR: $*" >&2; exit 1; }

require_bins() {
    for bin in "$@"; do
        command -v "$bin" >/dev/null 2>&1 || die "missing local dependency: $bin (install it and re-run)"
    done
}

# Validate a Docker container name. Same rules as Docker itself
# (https://github.com/moby/moby/blob/master/daemon/names/names.go).
validate_container_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] \
        || die "invalid container name: $(printf %q "$name") (must match [A-Za-z0-9][A-Za-z0-9_.-]*)"
}

# Validate an SSH target. Empty → local mode.
# Otherwise must look like [user@]host[:port]; must NOT begin with '-' (option injection)
# and must contain only chars allowed in user/host.
validate_ssh_target() {
    local t="$1"
    [ -z "$t" ] && return 0
    case "$t" in
        -*) die "ssh target starts with '-' (option injection blocked): $(printf %q "$t")" ;;
    esac
    [[ "$t" =~ ^([a-zA-Z0-9._-]+@)?[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] \
        || die "invalid SSH target: $(printf %q "$t") (expected user@host or host)"
}

# Validate a timestamp string used as a backup-dir suffix.
validate_timestamp() {
    local t="$1"
    [[ "$t" =~ ^[0-9]{8}-[0-9]{6}$ ]] \
        || die "invalid timestamp: $(printf %q "$t") (expected YYYYMMDD-HHMMSS)"
}

# Validate a heartbeat interval like "6h", "30m", "1d". Cron-style minimum.
validate_heartbeat() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+[smhd]$ ]] \
        || die "invalid heartbeat interval: $(printf %q "$v") (expected like 6h / 30m / 1d)"
}

# Validate a numeric Telegram user/chat ID.
validate_telegram_id() {
    local v="$1"
    [[ "$v" =~ ^-?[0-9]+$ ]] \
        || die "invalid Telegram ID: $(printf %q "$v") (expected integer)"
}

# Read & schema-validate config.json.
# Sets globals: REMOTE CONTAINER OWNER_TG OWNER_NAME TIMEZONE LANGUAGE BOT_NAME HEARTBEAT_EVERY
load_config() {
    local cfg="$1"
    [ -f "$cfg" ] || die "config not found: $cfg"
    require_bins jq
    jq -e . "$cfg" >/dev/null 2>&1 || die "config is not valid JSON: $cfg"

    REMOTE=$(jq -r '.remote.host // ""' "$cfg")
    CONTAINER=$(jq -r '.remote.container // "openclaw"' "$cfg")
    OWNER_TG=$(jq -r '.owner.telegramId // empty' "$cfg")
    OWNER_NAME=$(jq -r '.owner.name // empty' "$cfg")
    TIMEZONE=$(jq -r '.owner.timezone // "UTC"' "$cfg")
    LANGUAGE=$(jq -r '.owner.language // "en"' "$cfg")
    BOT_NAME=$(jq -r '.bot.name // empty' "$cfg")
    HEARTBEAT_EVERY=$(jq -r '.limits.heartbeatEvery // "6h"' "$cfg")

    [ -n "$OWNER_TG" ]   || die "config: owner.telegramId is required"
    [ -n "$OWNER_NAME" ] || die "config: owner.name is required"
    [ -n "$BOT_NAME" ]   || die "config: bot.name is required"

    validate_ssh_target     "$REMOTE"
    validate_container_name "$CONTAINER"
    validate_telegram_id    "$OWNER_TG"
    validate_heartbeat      "$HEARTBEAT_EVERY"
}

# Run a command remotely (via ssh) or locally (if REMOTE empty).
# Args: a single shell command string. The command MUST quote any
# user-supplied values BY THE CALLER (use printf %q "$VAR").
ssh_exec() {
    if [ -z "${REMOTE:-}" ]; then
        bash -c "$1"
    else
        # shellcheck disable=SC2029
        ssh -o ConnectTimeout=10 -- "$REMOTE" "$1"
    fi
}

scp_to() {
    local src="$1" dst="$2"
    if [ -z "${REMOTE:-}" ]; then
        cp -- "$src" "$dst"
    else
        scp -q -- "$src" "$REMOTE:$dst"
    fi
}
