#!/usr/bin/env node
// Filter: reads existing openclaw.json from stdin, writes patched version to stdout.
// Deep-merges the budget block; preserves any existing user customizations.
//
// Usage:
//   ssh "$REMOTE" "cat /root/.openclaw/openclaw.json" \
//     | node patch-openclaw-json.mjs <config.json> \
//     | ssh "$REMOTE" "cat > /root/.openclaw/openclaw.json.new"

import fs from 'node:fs';

const [, , configPath] = process.argv;
if (!configPath) {
    console.error('Usage: patch-openclaw-json.mjs <config.json>  (existing openclaw.json on stdin)');
    process.exit(1);
}

const cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));

// Read all of stdin
const stdin = fs.readFileSync(0, 'utf8');
let existing;
try {
    existing = JSON.parse(stdin);
} catch (e) {
    console.error(`ERROR: stdin is not valid JSON (${e.message})`);
    console.error('       Did you pipe the contents of /root/.openclaw/openclaw.json?');
    process.exit(2);
}

// Defensive deep-clone so we don't mutate the input.
const out = JSON.parse(JSON.stringify(existing));

// --- Apply budget block ---

out.agents = out.agents ?? {};
out.agents.defaults = out.agents.defaults ?? {};
out.agents.defaults.model = out.agents.defaults.model ?? {};
out.agents.defaults.model.primary = 'openai-codex/gpt-5.5';

// Fallback merge: drop paid/blocked, ensure Gemini is present, preserve other custom fallbacks.
const BLOCKED_FALLBACK_PREFIXES = ['anthropic/', 'openai/gpt-4o-mini'];
const REQUIRED_FALLBACK = 'google/gemini-3.1-pro-preview';
const existingFallbacks = Array.isArray(out.agents.defaults.model.fallbacks)
    ? out.agents.defaults.model.fallbacks.filter(
          (m) => typeof m === 'string' && !BLOCKED_FALLBACK_PREFIXES.some((p) => m.startsWith(p))
      )
    : [];
if (!existingFallbacks.includes(REQUIRED_FALLBACK)) existingFallbacks.unshift(REQUIRED_FALLBACK);
out.agents.defaults.model.fallbacks = existingFallbacks;

out.agents.defaults.heartbeat = out.agents.defaults.heartbeat ?? {};
out.agents.defaults.heartbeat.every = cfg.limits?.heartbeatEvery || '6h';

// Tools profile + allow/deny
out.tools = out.tools ?? {};
out.tools.profile = 'coding';
const requiredAllow = ['read', 'write', 'edit', 'apply_patch', 'exec', 'process'];
const existingAllow = Array.isArray(out.tools.allow) ? out.tools.allow : [];
out.tools.allow = Array.from(new Set([...existingAllow, ...requiredAllow]));

const requiredDeny = ['image', 'image_generate', 'code_execution', 'browser', 'x_search'];
const existingDeny = Array.isArray(out.tools.deny) ? out.tools.deny : [];
out.tools.deny = Array.from(new Set([...existingDeny, ...requiredDeny]));

// Telegram channel — allowlist mode, owner only, groups disabled.
out.channels = out.channels ?? {};
out.channels.telegram = out.channels.telegram ?? {};
const tg = out.channels.telegram;
tg.enabled = true;
tg.dmPolicy = 'allowlist';
tg.groupPolicy = 'disabled';
const ownerId = Number(cfg.owner.telegramId);
if (!Number.isInteger(ownerId)) {
    console.error(`ERROR: owner.telegramId is not an integer: ${cfg.owner.telegramId}`);
    process.exit(2);
}
// Preserve only entries that are already valid integers; reject and warn on garbage.
const existingAllowFrom = Array.isArray(tg.allowFrom) ? tg.allowFrom : [];
const cleanedAllowFrom = [];
for (const v of existingAllowFrom) {
    if (Number.isInteger(v)) {
        cleanedAllowFrom.push(v);
    } else if (typeof v === 'string' && /^-?\d+$/.test(v.trim())) {
        cleanedAllowFrom.push(Number(v));
    } else {
        console.error(`  warning: dropping non-numeric allowFrom entry: ${JSON.stringify(v)}`);
    }
}
if (!cleanedAllowFrom.includes(ownerId)) cleanedAllowFrom.push(ownerId);
// Stable order: deduplicate while preserving insertion order.
tg.allowFrom = [...new Set(cleanedAllowFrom)];

// Remove anthropic from providers list (fallbacks already handled above).
if (out.models?.providers && typeof out.models.providers === 'object') {
    delete out.models.providers.anthropic;
}

// --- Diff summary on stderr (so stdout stays clean for piping) ---
function diffSummary(before, after) {
    const lines = [];
    const checks = [
        ['agents.defaults.model.primary', before.agents?.defaults?.model?.primary, after.agents?.defaults?.model?.primary],
        ['agents.defaults.model.fallbacks', JSON.stringify(before.agents?.defaults?.model?.fallbacks), JSON.stringify(after.agents.defaults.model.fallbacks)],
        ['agents.defaults.heartbeat.every', before.agents?.defaults?.heartbeat?.every, after.agents.defaults.heartbeat.every],
        ['tools.profile', before.tools?.profile, after.tools.profile],
        ['tools.allow', JSON.stringify(before.tools?.allow), JSON.stringify(after.tools.allow)],
        ['tools.deny', JSON.stringify(before.tools?.deny), JSON.stringify(after.tools.deny)],
        ['channels.telegram.dmPolicy', before.channels?.telegram?.dmPolicy, after.channels.telegram.dmPolicy],
        ['channels.telegram.allowFrom', JSON.stringify(before.channels?.telegram?.allowFrom), JSON.stringify(after.channels.telegram.allowFrom)],
        ['channels.telegram.groupPolicy', before.channels?.telegram?.groupPolicy, after.channels.telegram.groupPolicy],
    ];
    for (const [key, b, a] of checks) {
        if (b !== a) lines.push(`  ${key}\n      before: ${b ?? '(unset)'}\n      after:  ${a}`);
    }
    return lines;
}

const changes = diffSummary(existing, out);
if (changes.length === 0) {
    console.error('  no changes — config already tuned (writing identical content)');
} else {
    console.error(`  ${changes.length} field(s) changed:`);
    for (const line of changes) console.error(line);
}

process.stdout.write(JSON.stringify(out, null, 2) + '\n');
