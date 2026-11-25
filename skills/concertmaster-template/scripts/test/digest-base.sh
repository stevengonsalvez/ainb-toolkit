#!/usr/bin/env bash
# digest-base.sh (test library, sourced by digest-fuzz.sh and field-reads.sh; not a test). The MAXIMAL base fixture of
# digest.sh: every field the digest reads from the ledger and from the gh and fleet CLI answers is present on at least one
# row, and every ledger row kind carries every field digest.sh type-checks (scripts/test/fixtures/digest-fields.tsv lists
# them). Fields that are inert on a row are an explicit null (a legal value), so a wrong-typed value can be put exactly
# where a null protects nothing but a count or a line. mkdigestbase <dir> writes <dir>/{cm/ledger.json,merged.json,open.json,
# runs.json,run-901.json,wt.json}. Needs ago (hours). Synthetic names only.

mkdigestbase() { # mkdigestbase <dir>
  local BASE="$1" A1 A3
  A1="$(ago 1)"; A3="$(ago 3)"
# the rich fixture: every input digest.sh reads, each field it reads present once
jq -n --arg a1 "$A1" --arg a3 "$A3" '{
  schema: "concertmaster.ledger/v1",
  digests: {lastSentAt: $a3},
  priorities: [{id: "p-1", rank: 1, what: "ship the roster", owner: "lead-a", state: "active", report: "on track"}],
  workers: {"w-bo": {lane: "lane-z", task: "club roster", state: "blocked-on-owner", blockedQuestion: "which club first?", host: "host-a", pr: "acme-app#7"},
            "w-run": {lane: "lane-r", task: "card list", state: "running", host: "host-a", pr: 5},
            "w-st": {lane: "lane-s", task: "stuck one", state: "stuck", host: "host-a", lastOutputAt: $a3, nudges: 1}},
  prs: {"5": {number: 5, state: "open"}},
  deployWindows: [{id: "dw-1", tag: "v1.2.3", state: "done", finishedAt: $a1, at: $a1, prs: [5, 6]},
                  {id: "dw-2", tag: "v1.2.4", state: "stopped", finishedAt: $a1, at: $a1, blockedReason: "smoke red"}],
  asks: [{id: "a-merge", kind: "merge", scope: null, topic: null, state: "open", question: "merge #12 past the red e2e?", lane: "lane-x", issue: 12, askedAt: $a1,
          worker: null, path: null, noCode: null, pr: 12, files: null},
         {id: "a-ota", kind: "release", scope: null, topic: null, state: "open", question: "push the OTA release", askedAt: $a1,
          lane: null, path: null, noCode: null, pr: null, worker: null, files: null},
         {id: "a-code", kind: "code", state: "open", question: "split the card list?", files: ["src/components/Card.tsx"], worker: "w-run", askedAt: $a1, scope: null, topic: null, path: "/w/acme/lane-r", noCode: false, pr: "acme-app#12", lane: null},
         {id: "a-verdict", kind: "code", state: "answered", question: "old one", issue: 7, decidedBy: "verdict-agent", decidedAt: $a1, verdictRef: "https://example.invalid/v"}],
  hosts: {"host-a": {reachable: true}, "host-b": {reachable: false}},
  followUps: [{id: "fu-1", lane: "lane-r", owner: "lead-a", worker: "w-run", text: "check the card", state: "open", openedAt: $a1}],
  hostEvents: [{at: $a1, kind: "reboot", watched: true}],
  health: {checkedAt: $a1, summary: {running: 2, idle: 1, "waiting on you": 1, stuck: 1, stopped: 0, asleep: 0, unknown: 0}, attention: [{name: "lane-s", host: "host-a", word: "stuck", meaning: "no output"}]},
  decisions: [{id: "d-1", at: $a1, subject: {kind: "pr", name: "#77", host: "host-a"}, rung: 3, text: "merged 77 first"}],
  violations: [{host: "host-a", worktree: "wt-v", handle: "h", title: "banned agent on acme", agent: "banned-agent"}],
  violationCheck: {enabled: true, complete: false, gaps: ["host-b not read"], checkedAt: $a1},
  supabaseStacks: {orphans: [{host: "host-a", projectId: "proj-x", containers: 3}], complete: false, gaps: ["host-b"], checkedAt: $a1},
  queue: {items: [{id: "q-1", issue: 41, summary: "next one", lane: "lane-q", priority: "P0", state: "queued", addedAt: $a1}]}
}' > "$BASE/cm/ledger.json"
jq -n --arg a1 "$A1" '[{number: 11, title: "feat(roster): add the roster (#11)", mergedAt: $a1, author: {login: "dev-a"}, url: "https://example.invalid/11",
                         files: [{path: "src/roster.ts"}]},
                        {number: 12, title: "chore(concertmaster): tooling", mergedAt: $a1, author: {login: "dev-b"}, url: "https://example.invalid/12",
                         files: [{path: ".agents/skills/concertmaster/x.sh"}]}]' > "$BASE/merged.json"
jq -n '[{number: 21, title: "fix(cards): card list", isDraft: false, reviewDecision: "REVIEW_REQUIRED", files: [{path: "src/cards.ts"}]},
        {number: 22, title: "docs(concertmaster): notes", isDraft: true, reviewDecision: "", files: [{path: ".agents/skills/concertmaster/n.md"}]}]' > "$BASE/open.json"
jq -n --arg a1 "$A1" '[{databaseId: 901, headBranch: "v1.2.3", status: "completed", conclusion: "success", createdAt: $a1, updatedAt: $a1}]' > "$BASE/runs.json"
jq -n --arg a1 "$A1" '{jobs: [{name: "Ship to Prod", conclusion: "success", completedAt: $a1}, {name: "Unit Tests", conclusion: "failure", completedAt: $a1}]}' > "$BASE/run-901.json"
jq -n '{ok: true, result: {worktrees: [
  {path: "/w/acme/lane-blk", displayName: "lane-blk", comment: "cm:running build\ncm:blocked which table holds the backfill?"},
  {path: "/w/acme/lane-r", displayName: "lane-r", comment: "cm:ask merge order for the reviewer?"},
  {path: "/w/acme/concertmaster", displayName: "concertmaster", comment: "cm:running tick\ncm:ask define the lease"}]}}' > "$BASE/wt.json"

}
