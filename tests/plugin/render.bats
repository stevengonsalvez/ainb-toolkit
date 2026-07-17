#!/usr/bin/env bats
load helpers

setup() {
  cd "$BATS_TEST_TMPDIR"
  git init -q repo && cd repo
  git config user.email t@t && git config user.name t && git config commit.gpgsign false
  echo x > f && git add f && git commit -qm init
}

@test "renderer produces token-free HTML with epic and feature rows" {
  run python3 "$SCRIPTS/render_dashboard.py" \
    --state "$FX/state.json" --beads "$FX/issues.jsonl" \
    --charter "$FX/charter.md" --repo "$PWD" --out out.html
  [ "$status" -eq 0 ]
  ! grep -qE '\{\{[A-Z_]+\}\}' out.html
  grep -q 'e01' out.html
  grep -q 'word counts' out.html
}

@test "renderer stamps staleness banner from --pending marker" {
  echo '{"step":"publish","error":"x","ts":"2026-07-16T18:00:00Z"}' > pend.json
  run python3 "$SCRIPTS/render_dashboard.py" \
    --state "$FX/state.json" --beads "$FX/issues.jsonl" \
    --charter "$FX/charter.md" --repo "$PWD" --pending pend.json --out out.html
  [ "$status" -eq 0 ]
  grep -q 'publishing degraded' out.html
}

@test "renderer without --pending renders no banner" {
  run python3 "$SCRIPTS/render_dashboard.py" \
    --state "$FX/state.json" --beads "$FX/issues.jsonl" \
    --charter "$FX/charter.md" --repo "$PWD" --out out.html
  [ "$status" -eq 0 ]
  ! grep -q 'publishing degraded' out.html
}

@test "renderer fails loudly on unreadable state" {
  run python3 "$SCRIPTS/render_dashboard.py" \
    --state /nonexistent.json --beads "$FX/issues.jsonl" \
    --charter "$FX/charter.md" --repo "$PWD" --out out.html
  [ "$status" -eq 1 ]
}

@test "renderer tolerates missing beads and charter (empty rows, still valid)" {
  run python3 "$SCRIPTS/render_dashboard.py" \
    --state "$FX/state.json" --beads /nonexistent.jsonl \
    --charter /nonexistent.md --repo "$PWD" --out out.html
  [ "$status" -eq 0 ]
  ! grep -qE '\{\{[A-Z_]+\}\}' out.html
}

@test "renderer does NOT fail when DATA contains a double-brace token" {
  # A commit message, note, or bead title with {{...}} must not stall the
  # dashboard: the unresolved-token guard checks the TEMPLATE, not the data.
  jq '.current_note = "epic uses the {{slug}} placeholder"' "$FX/state.json" > st.json
  run python3 "$SCRIPTS/render_dashboard.py" \
    --state st.json --beads "$FX/issues.jsonl" \
    --charter "$FX/charter.md" --repo "$PWD" --out out.html
  [ "$status" -eq 0 ]
  grep -q 'placeholder' out.html
}

@test "renderer DOES fail on an unhandled TEMPLATE token (authoring bug)" {
  # cp the template and inject a token with no matching scalar
  cp "$REPO_ROOT/plugins/godmode/skills/godmode/assets/programme-dashboard.html" bad.html
  printf '\n<div>{{UNHANDLED_TOKEN}}</div>\n' >> bad.html
  run python3 "$SCRIPTS/render_dashboard.py" \
    --state "$FX/state.json" --beads "$FX/issues.jsonl" \
    --charter "$FX/charter.md" --repo "$PWD" --template bad.html --out out.html
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNHANDLED_TOKEN"* ]]
}
