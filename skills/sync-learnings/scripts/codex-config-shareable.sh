#!/usr/bin/env bash
# Print the SHAREABLE slice of a codex config.toml (default ~/.codex/config.toml)
# — the hand-authored preferences only, with $HOME reverse-interpolated.
#
# Why this exists: ~/.codex/config.toml is 99% runtime accretion. Codex appends a
# [projects."<abs path>"] block every time you trust a directory (including temp
# worktrees), plus hook state, plugin/marketplace install state, and MCP servers
# injected by the ChatGPT desktop app with absolute /Applications paths. None of
# that is portable, and the repo is PUBLIC — so sync repo-ward through this
# filter, never by copying the whole file.
#
# ALLOW-LIST, not deny-list: a section nobody has vetted (say [model_providers]
# with an internal base_url, or [sandbox_workspace_write] with client paths) must
# never reach a public repo just because it postdates this script. Unknown
# sections are dropped and NAMED on stderr so a genuinely shareable new
# preference gets noticed and added here deliberately.
#
# Usage:
#   codex-config-shareable.sh --out codex/config.toml [path/to/config.toml]
#   codex-config-shareable.sh --self-check
#
# Use --out, never `> file`: the shell truncates a redirect target before this
# script runs, so a fail-closed refusal would leave the baseline empty. --out
# writes a temp file and moves it into place only on success.
set -euo pipefail

# Sections safe to publish. Add deliberately, after checking the section holds no
# endpoint, path, credential or machine identifier.
ALLOW_SECTIONS='^[[](tui|notice|features|desktop)[]]$'
# Top-level (pre-first-section) keys safe to publish.
ALLOW_TOPLEVEL='^(project_doc_fallback_filenames|project_doc_max_bytes|model|model_reasoning_effort|model_verbosity|model_reasoning_summary|hide_agent_reasoning|personality|approvals_reviewer|plan_mode_reasoning_effort)[[:space:]]*='

shareable() {
    # Comments/blank lines are buffered and emitted only when what FOLLOWS them
    # is kept — a comment annotating a dropped [projects."/work/acme"] block is
    # itself machine-private and must not survive its section.
    awk -v allow="$ALLOW_SECTIONS" -v allowtop="$ALLOW_TOPLEVEL" '
        function flush(  i) { for (i = 1; i <= nbuf; i++) print buf[i]; nbuf = 0 }
        /^[[:space:]]*(#|$)/ { buf[++nbuf] = $0; next }
        /^\[/ {
            insection = 1
            keep = ($0 ~ allow)
            if (keep) { flush(); print } else { nbuf = 0 }
            next
        }
        {
            # A key line: kept only in the top-level block, and only if allowed.
            if (keep == 0 && insection == 0 && $0 ~ allowtop) { flush(); print }
            else if (keep == 1) { flush(); print }
            else nbuf = 0
        }
        /^\[/ { insection = 1 }
    ' "$1" | sed "s|$HOME|\$HOME|g" | cat -s
}

# Section/top-level names that were dropped, deduped, with any path or quoted
# argument stripped — a bare name is safe to print, `[projects."/work/acme"]` is not.
dropped_names() {
    awk -v allow="$ALLOW_SECTIONS" '
        /^\[/ && $0 !~ allow {
            name = $0
            sub(/^\[/, "", name); sub(/[].].*$/, "", name); gsub(/"/, "", name)
            if (!(name in seen)) { seen[name] = 1; print name }
        }
    ' "$1" | sort | tr '\n' ',' | sed 's/,$//; s/,/, /g'
}

if [ "${1:-}" = "--self-check" ]; then
    fixture="$(mktemp)"; out="$(mktemp)"; trap 'rm -f "$fixture" "$out"' EXIT
    cat > "$fixture" <<'EOF'
model = "gpt-5.6-terra"
model_verbosity = "low"
model_reasoning_summary = "none"
hide_agent_reasoning = true
notify = ["/Applications/Some.app/bin", "turn-ended"]

# explains the next section
[tui]
animations = false
show_tooltips = false
status_line = []
terminal_title = []
notifications = false

# work laptop only: acme client sandbox
[projects."/Users/x/work/acme"]
trust_level = "trusted"
model_verbosity = "high"

[model_providers.acme]
base_url = "https://llm.internal.acme.example/v1"
env_key = "ACME_LLM_KEY"
EOF
    got="$(shareable "$fixture")"
    for expected in 'model = "gpt-5.6-terra"' 'model_verbosity = "low"' 'model_reasoning_summary = "none"' 'hide_agent_reasoning = true' '[tui]' 'notifications = false' '# explains the next section'; do
        grep -qF -- "$expected" <<<"$got" || { echo "self-check FAILED: missing $expected"; exit 1; }
    done
    # Dropped sections, their keys, their comments, and any un-vetted section.
    for forbidden in 'projects' 'trust_level' 'model_verbosity = "high"' 'notify =' 'acme' 'model_providers' 'base_url' 'env_key'; do
        grep -qF -- "$forbidden" <<<"$got" && { echo "self-check FAILED: leaked $forbidden"; exit 1; }
    done

    # A refusal must NOT truncate an existing --out target, and must not echo the
    # value. The secret goes INSIDE an allowed section — a top-level one is
    # already dropped by the allow-list and would never reach the guard.
    printf '[tui]\napi_key = "sk-livesecretvalue0123456789"\n' > "$fixture"
    printf 'PRE-EXISTING\n' > "$out"
    if err="$("$0" --out "$out" "$fixture" 2>&1)"; then
        echo "self-check FAILED: credential fixture did not refuse"; exit 1
    fi
    grep -qF 'PRE-EXISTING' "$out" || { echo "self-check FAILED: --out target was clobbered on refusal"; exit 1; }
    grep -qF 'sk-livesecretvalue0123456789' <<<"$err" && { echo "self-check FAILED: refusal echoed the secret"; exit 1; }
    echo "self-check OK"
    exit 0
fi

OUT_FILE=""
if [ "${1:-}" = "--out" ]; then
    [ $# -ge 2 ] || { echo "--out needs a path" >&2; exit 1; }
    OUT_FILE="$2"; shift 2
fi

SRC="${1:-$HOME/.codex/config.toml}"
[ -f "$SRC" ] || { echo "no config.toml at $SRC" >&2; exit 1; }

OUT="$(shareable "$SRC")"

# Belt and braces on top of the allow-list. Report LOCATIONS ONLY: printing the
# matched line would put the secret in the session transcript and CI logs, which
# is the same exposure this guard exists to prevent.
if hits="$(grep -niE '(api[_-]?key|secret|password|bearer|authorization|env_key|[[:alnum:]_-]*token[[:alnum:]_-]*)[[:space:]]*=|sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{16,}' <<<"$OUT" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//; s/,/, /g')" && [ -n "$hits" ]; then
    echo "REFUSING: credential-shaped value survived the allow-list at output line(s): $hits" >&2
    echo "          (value not printed on purpose) — scrub it, or narrow ALLOW_SECTIONS" >&2
    exit 2
fi

if [ -n "$OUT_FILE" ]; then
    tmp="$(mktemp)"
    printf '%s\n' "$OUT" > "$tmp"
    mv "$tmp" "$OUT_FILE"
    echo "  wrote $OUT_FILE" >&2
else
    printf '%s\n' "$OUT"
fi

# Name what was dropped so a silent over-filter — or a new shareable preference
# sitting in an un-vetted section — is visible instead of assumed.
echo "  dropped sections: $(dropped_names "$SRC")" >&2
