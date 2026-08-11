#!/usr/bin/env bash
# Print the SHAREABLE slice of a codex config.toml (default ~/.codex/config.toml)
# on stdout — the hand-authored preferences only, with $HOME reverse-interpolated.
#
# Why this exists: ~/.codex/config.toml is 99% runtime accretion. Codex appends a
# [projects."<abs path>"] block every time you trust a directory (including temp
# worktrees), plus hook state, plugin/marketplace install state, and MCP servers
# injected by the ChatGPT desktop app with absolute /Applications paths. None of
# that is portable, and the repo is PUBLIC — so sync repo-ward through this
# filter, never by copying the whole file.
#
# Usage:  codex-config-shareable.sh [path/to/config.toml] > codex/config.toml
#         codex-config-shareable.sh --self-check
set -euo pipefail

# `[[]` not `\[` — awk -v strips the backslash and then reads a character class.
DROP_SECTIONS='^[[](projects[.]|hooks[.]state|tui[.]model_availability_nux|notice[.]model_migrations|marketplaces[.]|plugins[.]|mcp_servers[.]|shell_environment_policy)'
# Top-level keys holding absolute machine paths.
DROP_KEYS='^(notify)[[:space:]]*='

shareable() {
    # Comments/blank lines trailing a dropped section usually document the NEXT
    # section, so buffer them and emit only if that next section is kept.
    awk -v drop="$DROP_SECTIONS" -v dropkeys="$DROP_KEYS" '
        /^\[/ {
            skip = ($0 ~ drop)
            if (!skip) { for (i = 1; i <= nbuf; i++) print buf[i] }
            nbuf = 0
            if (skip) next
            print; next
        }
        skip {
            if ($0 ~ /^[[:space:]]*(#|$)/) buf[++nbuf] = $0; else nbuf = 0
            next
        }
        $0 ~ dropkeys { next }
        { print }
    ' "$1" | sed "s|$HOME|\$HOME|g" | cat -s
}

if [ "${1:-}" = "--self-check" ]; then
    fixture="$(mktemp)"; trap 'rm -f "$fixture"' EXIT
    cat > "$fixture" <<'EOF'
model = "gpt-5.6-terra"
notify = ["/Applications/Some.app/bin", "turn-ended"]

[projects."/tmp/scratch"]
trust_level = "trusted"

# explains the next section
[otel]
environment = "local"

[mcp_servers.node_repl]
command = "/Applications/ChatGPT.app/bin/node_repl"
EOF
    got="$(shareable "$fixture")"
    for expected in 'model = "gpt-5.6-terra"' '[otel]' '# explains the next section'; do
        grep -qF -- "$expected" <<<"$got" || { echo "self-check FAILED: missing $expected"; exit 1; }
    done
    for forbidden in 'projects.' 'trust_level' 'notify =' 'mcp_servers' 'ChatGPT.app'; do
        grep -qF -- "$forbidden" <<<"$got" && { echo "self-check FAILED: leaked $forbidden"; exit 1; }
    done
    echo "self-check OK"
    exit 0
fi

SRC="${1:-$HOME/.codex/config.toml}"
[ -f "$SRC" ] || { echo "no config.toml at $SRC" >&2; exit 1; }

OUT="$(shareable "$SRC")"

# The repo is public. Refuse to emit anything that smells like a credential —
# a false positive costs one manual look, a miss is a leaked secret.
if grep -niE '(api[_-]?key|secret|password|bearer|authorization|[[:alnum:]_-]*token[[:alnum:]_-]*)[[:space:]]*=|sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{16,}' <<<"$OUT" >&2; then
    echo "REFUSING: credential-shaped value survived the filter (see matches above); scrub it before syncing" >&2
    exit 2
fi

printf '%s\n' "$OUT"

# Report what was dropped so a silent over-filter is visible, not assumed.
echo "  dropped $(grep -cE "$DROP_SECTIONS" "$SRC") machine/runtime sections from $SRC" >&2
