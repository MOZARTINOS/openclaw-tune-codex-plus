#!/usr/bin/env node
// ChatGPT Plus / Pro Codex usage limits via Codex OAuth endpoint headers.
// Makes a minimal probe request (~28 tokens) and parses x-codex-* response headers.
// Output language: English. Replace strings if you want to localize.

const fs = require('node:fs');

const AUTH_PATH = '/home/node/.openclaw/.codex/auth.json';
const CACHE_PATH = '/home/node/.openclaw/workspace/.cache/chatgpt_limits.json';
const CACHE_TTL_MS = 3 * 60 * 1000;
// Probe model only — has no effect on your actual chat routing.
// Any model your subscription is entitled to works.
const PROBE_MODEL = process.env.LIMITS_PROBE_MODEL || 'gpt-5.4';

function readCache() {
    try {
        const cached = JSON.parse(fs.readFileSync(CACHE_PATH, 'utf8'));
        if (cached?.output && Date.now() - cached.ts < CACHE_TTL_MS) return cached;
    } catch (_) {}
    return null;
}

function writeCache(output) {
    try {
        fs.mkdirSync(require('node:path').dirname(CACHE_PATH), { recursive: true });
        fs.writeFileSync(CACHE_PATH, JSON.stringify({ ts: Date.now(), output }, null, 2));
    } catch (_) {}
}

function makeBar(percent, width = 10) {
    const p = Math.max(0, Math.min(100, percent));
    const filled = Math.round((p / 100) * width);
    return '█'.repeat(filled) + '░'.repeat(width - filled);
}

function fmtDuration(seconds) {
    const s = Math.max(0, Math.floor(seconds));
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    if (d > 0) return `${d}d ${h}h`;
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
}

function fmtWindow(minutes) {
    const m = parseInt(minutes, 10);
    if (m >= 1440) return `${Math.round(m / 1440)}d`;
    if (m >= 60) return `${Math.round(m / 60)}h`;
    return `${m}m`;
}

(async () => {
    try {
        const cached = process.argv.includes('--fresh') ? null : readCache();
        if (cached) {
            const ageSec = Math.max(1, Math.floor((Date.now() - cached.ts) / 1000));
            console.log(`${cached.output}\n\n↻ cached ${ageSec}s ago (use --fresh to bypass)`);
            return;
        }

        const auth = JSON.parse(fs.readFileSync(AUTH_PATH, 'utf8'));
        const token = auth.tokens?.access_token;
        const accountId = auth.tokens?.account_id || '';
        if (!token) throw new Error('no access_token in auth.json');

        const body = {
            model: PROBE_MODEL,
            instructions: 'You are a ping responder. Reply with a single dot.',
            input: [{ role: 'user', content: [{ type: 'input_text', text: '.' }] }],
            stream: true,
            store: false,
            reasoning: { effort: 'none' },
        };

        const r = await fetch('https://chatgpt.com/backend-api/codex/responses', {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${token}`,
                'chatgpt-account-id': accountId,
                'OpenAI-Beta': 'responses=v1',
                'User-Agent': 'codex_cli_rs/0.124.0',
                'Content-Type': 'application/json',
                'Accept': 'text/event-stream',
                'originator': 'codex_cli_rs',
                'version': '0.124.0',
            },
            body: JSON.stringify(body),
        });

        if (r.status !== 200) {
            const txt = await r.text();
            throw new Error(`HTTP ${r.status}: ${txt.slice(0, 200)}`);
        }

        const h = Object.fromEntries(
            [...r.headers.entries()].filter(([k]) => k.toLowerCase().startsWith('x-codex-'))
        );

        const reader = r.body.getReader();
        while (!(await reader.read()).done) { /* discard */ }

        const plan = h['x-codex-plan-type'] || '?';
        const tier = h['x-codex-active-limit'] || '?';
        const primaryPct = parseInt(h['x-codex-primary-used-percent'] || '0', 10);
        const primaryResetSec = parseInt(h['x-codex-primary-reset-after-seconds'] || '0', 10);
        const primaryWindow = h['x-codex-primary-window-minutes'] || '?';
        const secondaryPct = parseInt(h['x-codex-secondary-used-percent'] || '0', 10);
        const secondaryResetSec = parseInt(h['x-codex-secondary-reset-after-seconds'] || '0', 10);
        const secondaryWindow = h['x-codex-secondary-window-minutes'] || '?';
        const creditsUnlimited = (h['x-codex-credits-unlimited'] || '').toLowerCase() === 'true';
        const creditsHas = (h['x-codex-credits-has-credits'] || '').toLowerCase() === 'true';
        const creditsBalance = (h['x-codex-credits-balance'] || '').trim();

        const primaryLeft = 100 - primaryPct;
        const secondaryLeft = 100 - secondaryPct;

        let out = `📊 <b>Codex OAuth usage (${plan.toUpperCase()})</b>\n\n`;
        out += `⏱️ ${fmtWindow(primaryWindow)} window:  ${makeBar(primaryPct)} ${primaryPct}% used / ${primaryLeft}% left\n`;
        out += `   ↳ Resets in: ${fmtDuration(primaryResetSec)}\n\n`;
        out += `📅 ${fmtWindow(secondaryWindow)} window: ${makeBar(secondaryPct)} ${secondaryPct}% used / ${secondaryLeft}% left\n`;
        out += `   ↳ Resets in: ${fmtDuration(secondaryResetSec)}\n\n`;

        if (creditsUnlimited) {
            out += `💰 Credits: unlimited`;
        } else if (creditsHas && creditsBalance) {
            out += `💰 Credits: ${creditsBalance}`;
        } else {
            out += `💰 Credits: —`;
        }
        out += `\n🎯 Tier: ${tier}`;

        writeCache(out);
        console.log(out);
    } catch (err) {
        console.error('Error:', err.message);
        process.exit(1);
    }
})();
