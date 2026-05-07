#!/usr/bin/env node
// Render bootstrap files from templates/ into a staging directory.
// Substitutes {{VAR}} placeholders from config.json.
// Asserts each file <= 12 KB and total <= 60 KB BEFORE deploy.
//
// Usage: node render-bootstrap.mjs <config.json> <out-dir>

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const TEMPLATES_DIR = path.join(REPO_ROOT, 'templates');

// Engine constraints — match OpenClaw's bootstrap-budget defaults.
const PER_FILE_LIMIT = 12_000;
const TOTAL_LIMIT = 60_000;

const [, , configPath, outDir] = process.argv;
if (!configPath || !outDir) {
    console.error('Usage: render-bootstrap.mjs <config.json> <out-dir>');
    process.exit(1);
}

const cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));

// All known substitutions. Anything else falls through with a warning.
const vars = {
    OWNER_NAME:       cfg.owner.name,
    OWNER_TG_ID:      String(cfg.owner.telegramId),
    TIMEZONE:         cfg.owner.timezone || 'UTC',
    LANGUAGE:         cfg.owner.language || 'en',
    QUIET_HOURS:      cfg.owner.quietHours || '01:00-07:00',
    BOT_NAME:         cfg.bot.name,
    BOT_EMOJI:        cfg.bot.emoji || '🤖',
    CHARACTER_BLURB:  cfg.bot.characterBlurb || 'Pragmatic, concise, helpful.',
};

// Files to render. Source name → target name (after substitution).
// Files with .tmpl get substitution + .tmpl stripped. Plain .md/.toml ship as-is.
const RENDERABLE = [
    { src: 'AGENTS.md.tmpl',     dst: 'AGENTS.md',    requireSubst: true },
    { src: 'MEMORY.md.tmpl',     dst: 'MEMORY.md',    requireSubst: true },
    { src: 'TOOLS.md.tmpl',      dst: 'TOOLS.md',     requireSubst: true },
    { src: 'IDENTITY.md.tmpl',   dst: 'IDENTITY.md',  requireSubst: true },
    { src: 'USER.md.tmpl',       dst: 'USER.md',      requireSubst: true },
    { src: 'HEARTBEAT.md.tmpl',  dst: 'HEARTBEAT.md', requireSubst: true },
    { src: 'SOUL.md',            dst: 'SOUL.md',      requireSubst: false },
];

function render(src, requireSubst) {
    const raw = fs.readFileSync(path.join(TEMPLATES_DIR, src), 'utf8');
    if (!requireSubst) return raw;

    const seen = new Set();
    const result = raw.replace(/{{([A-Z_][A-Z0-9_]*)}}/g, (_, key) => {
        seen.add(key);
        if (!(key in vars)) {
            throw new Error(`Unknown template variable {{${key}}} in ${src}. Add it to render-bootstrap.mjs vars{}.`);
        }
        return vars[key];
    });

    // Sanity: did the template have NO substitutions despite being requireSubst?
    // That's fine, but worth flagging during dev.
    if (seen.size === 0) {
        console.error(`  warning: ${src} had no {{VAR}} placeholders (could be moved to requireSubst:false)`);
    }

    return result;
}

fs.mkdirSync(outDir, { recursive: true });
let total = 0;
let failed = false;

console.log(`Rendering ${RENDERABLE.length} bootstrap files → ${outDir}`);
for (const { src, dst, requireSubst } of RENDERABLE) {
    let body;
    try {
        body = render(src, requireSubst);
    } catch (e) {
        console.error(`  ERROR: ${src} → ${e.message}`);
        failed = true;
        continue;
    }
    const bytes = Buffer.byteLength(body, 'utf8');
    total += bytes;
    fs.writeFileSync(path.join(outDir, dst), body, 'utf8');

    const status = bytes > PER_FILE_LIMIT ? '✗' : '✓';
    console.log(`  ${status} ${dst.padEnd(16)} ${bytes.toString().padStart(5)} bytes`);
    if (bytes > PER_FILE_LIMIT) {
        console.error(`     EXCEEDS PER-FILE LIMIT (${PER_FILE_LIMIT} bytes) — engine will truncate`);
        failed = true;
    }
}

console.log(`  ─────────────────────────────`);
const totalStatus = total > TOTAL_LIMIT ? '✗' : '✓';
console.log(`  ${totalStatus} TOTAL            ${total.toString().padStart(5)} bytes (limit ${TOTAL_LIMIT})`);

if (total > TOTAL_LIMIT) {
    console.error(`     EXCEEDS TOTAL LIMIT — engine will truncate the last file(s)`);
    failed = true;
}

if (failed) {
    console.error('\nRENDER FAILED — fix templates or shrink content.');
    process.exit(2);
}

// Also stage the codex-config.toml and chatgpt_limits.js as separate artifacts.
fs.copyFileSync(path.join(TEMPLATES_DIR, 'codex-config.toml'), path.join(outDir, 'codex-config.toml'));
fs.copyFileSync(path.join(TEMPLATES_DIR, 'chatgpt_limits.js'), path.join(outDir, 'chatgpt_limits.js'));

console.log('\nRENDER OK — ready to deploy.');
