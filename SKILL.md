---
name: openclaw-tune-codex-plus
description: Tune a fresh or existing OpenClaw Telegram bot for the $20 ChatGPT Plus Codex budget. Trims bootstrap, sets heartbeat=6h, pins Codex CLI to chatgpt mode, blocks paid fallbacks. Use when setting up a new OpenClaw bot or debugging why the Codex weekly quota dies in days.
version: 0.1.0
metadata:
  clawdbot:
    emoji: 💰
    requires:
      bins: [ssh, scp, jq, node]
---

# openclaw-tune-codex-plus

Apply the budget-tuning recipe to a remote OpenClaw bot so it fits on ChatGPT Plus.

## When to use

- Setting up a new OpenClaw bot for someone on a $20/mo Codex Plus plan.
- Debugging an existing bot whose weekly Codex quota dies in 1–3 days.
- Re-tuning after an OpenClaw image upgrade reset configs.

## When NOT to use

- The bot is on a paid-per-token API (this skill assumes subscription).
- OpenClaw is older than `2026.4.22` (different `tools.profile` semantics — upgrade first).
- The bot isn't installed yet — this skill tunes existing installs only.

## Inputs

The skill prompts the user (or reads `~/.openclaw-tune-codex-plus/<host>.json` if present):

1. SSH target (`user@host`)
2. Container name (default `openclaw`)
3. Owner first name
4. Owner Telegram numeric ID (for `channels.telegram.allowFrom`)
5. Timezone (e.g. `Europe/Berlin`)
6. Bot name + 1-line character blurb
7. Reply language (default `en`)

Optional: `GEMINI_API_KEY` env var (skill prompts if absent).

## Workflow

### Phase 0 — Preflight

```bash
./scripts/preflight.sh "$REMOTE" "$CONTAINER"
```

Verifies: container running, image is OpenClaw `≥2026.4.22`, `auth_mode=chatgpt`, `OPENAI_API_KEY` not in container env, Codex CLI `≥0.124.0`. Exits non-zero with a fix list on any blocker.

### Phase 1 — Backup

```bash
ssh "$REMOTE" "mkdir -p /root/openclaw-tune-backup-\$(date +%Y%m%d-%H%M%S) && \
  cp -r /root/.openclaw/{openclaw.json,workspace,.codex} \
     /root/openclaw-tune-backup-\$(date +%Y%m%d-%H%M%S)/"
```

### Phase 2 — Render bootstrap locally

```bash
node scripts/render-bootstrap.mjs config.json out/
```

Substitutes `{{VARS}}` in `templates/*.tmpl`, asserts each file ≤12 KB and total ≤60 KB. Fails locally if templates can't fit; never breaks the remote.

### Phase 3 — Patch openclaw.json (deep-merge)

```bash
ssh "$REMOTE" "cat /root/.openclaw/openclaw.json" | \
  node scripts/patch-openclaw-json.mjs config.json | \
  ssh "$REMOTE" "cat > /root/.openclaw/openclaw.json.new"
```

Deep-merges the budget block (model.primary, fallbacks, heartbeat=6h, tools.profile/allow/deny, channels.telegram allowlist, removes anthropic provider). Preserves any unrelated keys the user has set.

### Phase 4 — Deploy

```bash
./scripts/deploy.sh "$REMOTE" "$CONTAINER" out/
```

Tars staged bootstrap + Codex configs (3 paths) + `chatgpt_limits.js`, scp's, unpacks, chowns to `1000:1000`, swaps `openclaw.json.new`, restarts container.

### Phase 5 — Verify

```bash
./scripts/verify.sh "$REMOTE" "$CONTAINER"
```

Re-checks `auth_mode`, runs `/limits` probe, byte-counts bootstrap. Refuses success if `auth_mode != chatgpt` (Codex CLI may have flipped to apikey on restart — that's a known regression).

### Rollback

```bash
./scripts/rollback.sh "$REMOTE" <timestamp>
```

Restores from `/root/openclaw-tune-backup-<ts>/`, restarts container.

## Reference deployment

The recipe was developed on a real production bot. See [Niklas's bot](https://github.com/MOZARTINOS/clawd-bot) for an example of what a tuned `openclaw.json` and trimmed `workspace/*.md` look like in practice.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) — common errors (`bwrap: No permissions`, `refresh_token_reused`, Anthropic 5k threshold, Codex CLI flipping to apikey on restart).
