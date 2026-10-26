#!/usr/bin/env node
// Derive hooks/claude-codex-hooks.json from hooks/hooks.json.
// hooks.json resolves the plugin root through a shell variable so one file works under both the Claude
// and Codex plugin runtimes. apm can only relocate a literal "${CLAUDE_PLUGIN_ROOT}/path", so it reads
// this generated file instead. Native plugin runtimes ignore it. Usage: --write | --check | --print
const fs = require('fs');
const path = require('path');

const HOOKS = path.join(__dirname, '..', 'hooks');
const PRELUDE = /ROOT="\$\{CLAUDE_PLUGIN_ROOT\}";.*?exit 2; \}; /;

function toDirectForm(hooks) {
    const out = JSON.parse(JSON.stringify(hooks));
    for (const groups of Object.values(out.hooks || {})) {
        for (const g of groups) {
            for (const h of g.hooks || []) {
                if (typeof h.command === 'string') {
                    h.command = h.command.replace(PRELUDE, '').replace(/\$ROOT\//g, '${CLAUDE_PLUGIN_ROOT}/');
                }
            }
        }
    }
    return out;
}

function render() {
    const src = JSON.parse(fs.readFileSync(path.join(HOOKS, 'hooks.json'), 'utf8'));
    return JSON.stringify(toDirectForm(src), null, 2) + '\n';
}

if (require.main === module) {
    const target = path.join(HOOKS, 'claude-codex-hooks.json');
    const mode = process.argv[2];
    if (mode === '--write') fs.writeFileSync(target, render());
    else if (mode === '--check') process.exit(fs.existsSync(target) && fs.readFileSync(target, 'utf8') === render() ? 0 : 1);
    else if (mode === '--print') process.stdout.write(render());
    else { console.error('usage: gen-claude-codex-hooks.cjs --write | --check | --print'); process.exit(2); }
}

module.exports = { toDirectForm, render };
