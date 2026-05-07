# openclaw-tune-codex-plus

> Make your OpenClaw Telegram bot fit on the $20 ChatGPT Plus Codex budget.

A one-command tuner that trims an OpenClaw bot's system-prompt budget, pins the Codex CLI to subscription mode, and removes the paid-per-token fallbacks that quietly drain your wallet.

## Why

Out of the box, an OpenClaw bot on ChatGPT Plus burns through the weekly Codex quota in days:

- Default heartbeat fires every 30 minutes — eats ~58% of the weekly quota on idle ticks alone.
- Bootstrap files (`AGENTS.md`, `MEMORY.md`, `TOOLS.md`, …) ship at ~42 KB total → ~10k tokens of system prompt loaded on every request.
- Default fallback chain includes `openai/gpt-4o-mini` — paid per-token, not subscription.
- Codex CLI silently downgrades to apikey mode if `OPENAI_API_KEY` is in container env, switching the bot from $20/mo flat to per-token billing.

## What this does

- Trims bootstrap to ≤12 KB total (≤3k tokens), keeping engine constraints satisfied
- Sets `agents.defaults.heartbeat.every = "6h"`
- Pins Codex CLI to `forced_login_method = "chatgpt"`, `sandbox_mode = "danger-full-access"`, `approval_policy = "never"`
- Removes paid OpenAI fallback, keeps Gemini as a free safety net
- Locks Telegram channel to allowlist (DMs only from owner; groups disabled)
- Drops a `/limits` script you can run to see weekly Codex usage

## What it doesn't do

- Install OpenClaw or build the container — bring your own working bot.
- Register a Telegram bot with BotFather.
- Run the Codex OAuth login flow (`refresh-auth codex` is on you).
- Acquire a Gemini API key.

## Status

Pre-release. Tested on one production bot (OpenClaw `2026.4.23`, Codex CLI `0.124.0`). Public release after a friend-test cycle.

## Quick start

```bash
git clone <repo-url> openclaw-tune-codex-plus
cd openclaw-tune-codex-plus
./install.sh
```

The installer asks you 7 questions (SSH target, owner Telegram ID, timezone, bot name, …), saves your answers, then patches the remote bot. Re-running re-uses the saved answers — no prompts.

## Requirements

- Linux server with Docker and a working `openclaw` container
- OpenClaw image `≥ 2026.4.22`
- Codex CLI `≥ 0.124.0` inside the container
- Local: `bash`, `jq`, `node`, `ssh`, `scp`

## License

MIT — see [LICENSE](LICENSE).
