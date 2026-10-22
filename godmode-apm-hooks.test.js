const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// execSync keeps this jest-safe: the package is type:module and the generator is CommonJS.
const render = () => execSync('node plugins/godmode/scripts/gen-claude-codex-hooks.cjs --print', { cwd: __dirname }).toString();

const dir = path.join(__dirname, 'plugins', 'godmode', 'hooks');

describe('godmode apm hook file', () => {
    test('claude-codex-hooks.json is in sync with hooks.json', () => {
        expect(fs.readFileSync(path.join(dir, 'claude-codex-hooks.json'), 'utf8')).toBe(render());
    });

    test('every command is a direct ${CLAUDE_PLUGIN_ROOT}/ path with no shell-variable root', () => {
        const hooks = JSON.parse(fs.readFileSync(path.join(dir, 'claude-codex-hooks.json'), 'utf8')).hooks;
        const cmds = Object.values(hooks).flat().flatMap(g => g.hooks.map(h => h.command));
        expect(cmds.length).toBeGreaterThan(0);
        for (const c of cmds) {
            expect(c).toMatch(/^"\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\//);
            expect(c).not.toMatch(/\$ROOT|PLUGIN_ROOT\}";/);
        }
    });

    test('hooks.json is left on the shell-variable form the native runtimes use', () => {
        const hooks = JSON.parse(fs.readFileSync(path.join(dir, 'hooks.json'), 'utf8')).hooks;
        const cmds = Object.values(hooks).flat().flatMap(g => g.hooks.map(h => h.command));
        for (const c of cmds) expect(c).toContain('ROOT="${CLAUDE_PLUGIN_ROOT}"');
    });
});
