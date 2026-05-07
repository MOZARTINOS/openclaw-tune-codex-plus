# Troubleshooting

## "PREFLIGHT FAILED: auth_mode=apikey"

The bot is on per-token billing, not your subscription. Causes, in order of likelihood:

1. `OPENAI_API_KEY` is in the container's process env. Codex CLI auto-detects it on every restart and overwrites `auth.json` to apikey mode. Remove the var from `docker-compose.yml`, `.env`, or `docker run` flags. Verify: `docker exec <container> cat /proc/1/environ | tr '\0' '\n' | grep OPENAI`.
2. You've never run `codex login` interactively. Inside the container: `refresh-auth codex` (or `codex login --device-auth` directly).

After fixing, re-run `./install.sh`.

## "PREFLIGHT FAILED: codex 0.123.x < 0.124.0"

Older Codex CLI doesn't persist the rotated `refresh_token` after silent refresh, so OAuth dies after ~10 days. Upgrade by recreating the container with the latest `alpine/openclaw:latest` image (it bundles a newer Codex CLI), or `npm install -g @openai/codex@latest` inside the container.

## After deploy: bot says "I have no shell/exec/read access"

Five minutes of debugging order:

1. Check `tools.allow` actually contains the runtime tools:
   ```
   ssh root@host "jq '.tools.allow' /root/.openclaw/openclaw.json"
   ```
   Must include `read, write, edit, apply_patch, exec, process`. If missing, the patch didn't apply — check `deploy.sh` output for "PATCH PRODUCED INVALID JSON".

2. Check the Codex CLI sandbox config got written. There are three `config.toml` files; all need `sandbox_mode = "danger-full-access"`:
   ```
   ssh root@host "find /root/.openclaw -path '*codex*' -name config.toml -exec grep -H sandbox_mode {} +"
   ```

3. Check the Telegram session isn't polluted. After many refusals, the LLM can repeat refusals from chat history even when tools work. Test in a fresh session:
   ```
   docker exec <container> bash -c 'cd /home/node/.openclaw/workspace && \
     timeout 60 node /app/openclaw.mjs agent --json --session-id "fresh-$(date +%s)" \
     -m "Read AGENTS.md and tell me line 1"' | jq '.toolSummary'
   ```
   If this works but Telegram doesn't → session pollution. Stop the container, move the latest session jsonl in `/root/.openclaw/agents/main/sessions/` aside, restart. Loses chat history; workspace memory unaffected.

## "bwrap: No permissions to create a new namespace"

Codex CLI's `workspace-write` sandbox uses bubblewrap, which fails inside non-privileged Docker. `templates/codex-config.toml` ships with `sandbox_mode = "danger-full-access"` to skip bwrap and run commands directly — Docker container is the security boundary. If you've changed it back to `workspace-write`, change it back to `danger-full-access`.

## Anthropic 5k-token threshold

Not relevant to this tuner (we route to Codex / Gemini), but worth knowing if you're considering Anthropic Max as a fallback: the Claude subscription tier blocks structured system prompts above ~5k real-content tokens. Middleware that re-shapes prompts (Meridian, toolstrip-style proxies) can't bypass it. Don't add `anthropic/*` to fallbacks.

## "VERIFY FAILED: auth_mode='apikey' after restart"

This is the same regression as the preflight check, but it happened during the deploy's container restart. Most likely cause: `OPENAI_API_KEY` is still in the container env. The verifier refuses success — your bot is now on paid billing. Run `rollback.sh`, fix the env, re-run.

## Re-running install.sh on an already-tuned bot

Should be a near-noop (deep-merge preserves your customizations; the patch script reports "no changes" if everything matches). One known caveat: a backup directory and a container restart still happen unconditionally. If that's annoying for you, skip preflight+deploy by checking the diff manually:

```
ssh root@host "cat /root/.openclaw/openclaw.json" \
  | node scripts/patch-openclaw-json.mjs ./config.json \
  | diff - <(ssh root@host "cat /root/.openclaw/openclaw.json")
```

If the diff is empty, no need to deploy.

## Backups pile up

Each deploy creates `/root/openclaw-tune-backup-<ts>/`. They're not cleaned up. Once per quarter:

```
ssh root@host "ls -1d /root/openclaw-tune-backup-* | head -n -3 | xargs rm -rf"
```

(Keeps the 3 most recent.)
