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

All scripts take **a single argument**: the path to a `config.json` produced by `scripts/prompt-config.sh`. SSH target, container name, and owner data live in that file.

### Phase 0 — Preflight

```bash
./scripts/preflight.sh ./config.json
```

Verifies: local deps, SSH reach, container running, OpenClaw `≥2026.4.22`, `auth_mode=chatgpt`, `OPENAI_API_KEY` not in container env, Codex CLI `≥0.124.0`. Exits non-zero with a fix list on any blocker.

### Phase 1 — Render bootstrap locally

```bash
node scripts/render-bootstrap.mjs ./config.json out/
```

Substitutes `{{VARS}}` in `templates/*.tmpl`, asserts each file ≤12 KB and total ≤60 KB. Fails locally if templates can't fit; never breaks the remote.

### Phase 2 — Deploy (handles backup + patch + restart)

```bash
./scripts/deploy.sh ./config.json out/
```

Backs up `openclaw.json` + `workspace/` + `.codex/` + `harness-auth/` + `acp-auth/` to `/root/openclaw-tune-backup-<ts>/`, scp's the staged tarball, unpacks, chowns to `1000:1000`, drops `codex-config.toml` into all account dirs, atomically swaps in the patched `openclaw.json` (deep-merged via `patch-openclaw-json.mjs`), restarts the container.

### Phase 3 — Verify

```bash
./scripts/verify.sh ./config.json
```

Re-checks `auth_mode`, runs `/limits` probe, byte-counts bootstrap, confirms `tools.allow` and `channels.telegram.allowFrom`. Refuses success if anything regressed (e.g. `auth_mode` flipped to apikey on restart).

### Rollback

```bash
./scripts/rollback.sh ./config.json <timestamp>
```

Restores `openclaw.json` + `workspace/` + `.codex/` + `harness-auth/` + `acp-auth/` from `/root/openclaw-tune-backup-<ts>/`, restarts container.

## Reference deployment

The recipe was developed on a real production bot. See [Niklas's bot](https://github.com/MOZARTINOS/clawd-bot) for an example of what a tuned `openclaw.json` and trimmed `workspace/*.md` look like in practice.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) — common errors (`bwrap: No permissions`, `refresh_token_reused`, Anthropic 5k threshold, Codex CLI flipping to apikey on restart).
