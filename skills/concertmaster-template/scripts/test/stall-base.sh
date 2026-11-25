#!/usr/bin/env bash
# stall-base.sh (test library, sourced by stall-fuzz.sh and field-reads.sh; not a test). The MAXIMAL base fixture of
# stall.sh: every field the stall.sh program reads, on every kind of row of every input document (scripts/test/fixtures/
# stall-fields.tsv lists them), is present, and where its absence or a wrong type would read as "nothing there" the row is
# built so that a lane or a PR depends on it. Fields that are inert on a row are present as an explicit null (a legal
# value), so a wrong-typed value can be put exactly where a null protects something (a ledger ask followUp, kind, scope,
# pr or worker; a worker pr).
#
# Lanes that are protected (each by ONE protection; a wrong-typed value in its field must never let it ladder):
#   l-wait     a cm:waiting-owner worktree comment          l-own    an owner-only ledger ask (lane) that also names PR 11
#   l-ask      an asks.sh comment ask (cm:ask)               l-cb     an asks.sh comment ask (cm:blocked)
#   l-bo       a blocked-on-owner worker                     l-park   a parked worker (its item carries PR 20)
#   l-wid      a parked worker matched by worktreeId only    l-unread a host asks.sh did not read (hostsRead)
#   l-unr      a host in asks.sh unreachable                 l-trunc  a host whose worktree list was cut off
#   l-off      a host-offline item                           l-stand  standing-idle with nothing queued
#   l-child    a live lead's child (comment:lead-x)          l-del    a delegated release ask on the ladder
#   l-wk       an owner-only ask that names a worker         l-nc     an owner-only noCode ask whose worker has PR 21
#   l-main, l-other, l-dm, l-dsr, l-asleep   a class that is never stalled
#   l-self     the concertmaster itself (ownerSource self)   nt-lane  a worktrees.never_touch name (config)
# Lanes that ladder in the base (so a mutation may leave them laddering): l-free, l-orph (a child whose lead is dead),
# l-sq and l-sq2 (standing-idle WITH something queued), dev-sweeper (the ownership label of a follow-up ask holds no lane).
# PRs: 11 held by the ask pr (number), 12 label, 14 its lane l-bo, 15 collaborator (text), 16 another repo (the template has no extra-repo exemption: it ladders), 17 an ask pr as
# "repo#n", 18 collaborator (object author), 19 label (text member), 20 its lane l-park, 21 its lane l-nc, 22 an ask pr as a
# pull URL; 13 is free. mkbase <dir> <freeze json|null> writes <dir>/{cls,disc,asks,led}.json. Needs $T0 and ago (minutes).
# Synthetic names only.

mkbase() { # mkbase <dir> <freeze json>
  local d="$1"; mkdir -p "$d/cm"
  jq -n --arg g "$T0" '
    def item($n; $h; $c; $os; $o; $pr; $wid): {host: $h, class: $c, path: ("/w/acme/" + $n), repo: "acme-app", branch: ("b-" + $n),
      worktreeId: $wid, inOrca: true, idleMinutes: 95, pr: $pr, flags: [], reason: "r", suggest: "s", name: $n,
      owner: $o, ownerSource: $os};
    def open($n): {number: $n, state: "OPEN"};
    {schema: "concertmaster.classify/v1", generatedAt: $g,
     ownership: {configured: true, leadDead: [{lead: "lead-y", open: ["l-orph"]}]},
     items: [
      item("l-wait"; "local"; "idle"; "prefix"; "dev-sweeper"; null; "id-l-wait"),
      item("l-own"; "local"; "idle"; "prefix"; "dev-sweeper"; open(11); "id-l-own"),
      item("l-ask"; "local"; "idle"; "prefix"; "dev-sweeper"; null; "id-l-ask"),
      item("l-cb"; "local"; "idle"; "prefix"; "dev-sweeper"; null; "id-l-cb"),
      item("l-bo"; "local"; "idle"; "prefix"; "dev-sweeper"; open(14); "id-l-bo"),
      item("l-park"; "local"; "idle"; "prefix"; "dev-sweeper"; open(20); "id-l-park"),
      item("l-wid"; "local"; "idle"; "prefix"; "dev-sweeper"; null; "id-l-wid"),
      item("l-unread"; "hb"; "idle"; "prefix"; "dev-sweeper"; null; "id-l-unread"),
      item("l-unr"; "hu"; "idle"; "prefix"; "dev-sweeper"; null; "id-l-unr"),
      item("l-trunc"; "hz"; "idle"; "prefix"; "dev-sweeper"; null; "id-l-trunc"),
      item("l-off"; "ho"; "host-offline"; "prefix"; "dev-sweeper"; null; "id-l-off"),
      item("l-stand"; "local"; "standing-idle"; "standing"; "dev-sweeper"; null; "id-l-stand"),
      item("l-child"; "local"; "idle"; "comment:lead-x"; "lead-x"; null; "id-l-child"),
      item("l-del"; "local"; "idle"; "prefix"; "dev-sweeper"; null; "id-l-del"),
      item("l-wk"; "local"; "idle"; "prefix"; "dev-sweeper"; null; "id-l-wk"),
      item("l-nc"; "local"; "idle"; "prefix"; "dev-sweeper"; open(21); "id-l-nc"),
      item("l-main"; "local"; "main-checkout"; "prefix"; "dev-sweeper"; null; "id-l-main"),
      item("l-other"; "local"; "other-project"; "prefix"; "dev-sweeper"; null; "id-l-other"),
      item("l-dm"; "local"; "done-merged"; "prefix"; "dev-sweeper"; null; "id-l-dm"),
      item("l-dsr"; "local"; "done-selfreported"; "prefix"; "dev-sweeper"; null; "id-l-dsr"),
      item("l-asleep"; "local"; "idle"; "prefix"; "dev-sweeper"; null; "id-l-asleep"),
      item("l-self"; "local"; "idle"; "self"; "concertmaster"; null; "id-l-self"),
      item("nt-lane"; "local"; "idle"; "prefix"; "dev-sweeper"; null; "id-nt-lane"),
      item("l-free"; "local"; "idle"; "prefix"; "dev-sweeper"; null; "id-l-free"),
      item("l-orph"; "local"; "idle"; "comment:lead-y"; "lead-y"; null; "id-l-orph"),
      item("l-sq"; "local"; "standing-idle"; "standing"; "dev-q"; null; "id-l-sq"),
      item("l-sq2"; "local"; "standing-idle"; "standing"; "dev-r"; null; "id-l-sq2"),
      item("dev-sweeper"; "local"; "idle"; "prefix"; "dev-sweeper"; null; "id-dev-sweeper")]}' > "$d/cls.json"
  jq -n --arg g "$T0" --arg u "$(ago 200)" '
    def pr($n; $l; $a; $r): {number: $n, title: "t\($n)", isDraft: false, createdAt: $u, updatedAt: $u, url: "u", headRefName: "b\($n)",
      headRefOid: "s\($n)", author: $a, repo: $r, labels: $l};
    def host($n; $t): {name: $n, reachable: true, truncated: $t};
    {schema: "concertmaster.discover/v1", generatedAt: $g, mainRepo: "AcmeOrg/acme-app",
     hosts: [host("local"; false), host("hb"; false), host("hu"; false), host("hz"; true), host("ho"; false)],
     worktrees: [{host: "local", path: "/w/acme/l-wait", comment: "cm:running x\ncm:waiting-owner pick the club"},
                 {host: "local", path: "/w/acme/l-free", comment: "cm:running y"}],
     prs: {open: [pr(11; []; "alice"; null), pr(12; [{name: "do-not-merge"}]; "alice"; null), pr(13; []; "alice"; null),
                  pr(14; []; "alice"; null), pr(15; []; "pat-collab"; null), pr(16; []; "alice"; "acme-learning"),
                  pr(17; []; "alice"; null), pr(18; []; {login: "pat-collab"}; null), pr(19; ["do-not-merge"]; "alice"; null),
                  pr(20; []; "alice"; null), pr(21; []; "alice"; null), pr(22; []; "alice"; null)]},
     errors: [{where: "gh pr list closed", error: "x"}]}' > "$d/disc.json"
  jq -n --arg g "$T0" --arg f "$(ago 10)" '
    def row($w; $t): {host: "local", worktree: $w, path: ("/w/acme/" + $w), tag: $t, text: "which table?", firstSeen: $f};
    {generatedAt: $g, hostsRead: ["local", "hu", "hz", "ho"], unreachable: [{host: "hu", error: "ssh timed out"}], count: 2,
     asks: [row("l-ask"; "cm:ask"), row("l-cb"; "cm:blocked")]}' > "$d/asks.json"
  jq -n --arg a95 "$(ago 95)" --arg a5 "$(ago 5)" --arg ttl "$(ago -600)" --argjson fz "$2" '
    def ask($id; $k): {id: $id, state: "open", kind: $k, scope: null, question: "merge it?", topic: null, lane: null, worker: null,
      worktree: null, path: null, files: null, noCode: null, pr: null, followUp: null, issue: null, askedAt: $a95};
    def worker($path; $st): {path: $path, host: "local", state: $st, lane: "dev-sweeper", worktreeId: null, pr: null};
    {workers: {"w-bo": worker("/w/acme/l-bo"; "blocked-on-owner"),
               "w-park": worker("/w/acme/l-park"; "parked"),
               "w-wid": (worker("/w/elsewhere/wid"; "parked") + {worktreeId: "id-l-wid"}),
               "w-asleep": worker("/w/acme/l-asleep"; "asleep"),
               "w-ask": worker("/w/acme/l-wk"; "running"),
               "w-nc": (worker("/w/acme/l-nc"; "running") + {pr: 21})},
     asks: [(ask("a-own"; "merge") + {scope: "release", question: "push the OTA release", lane: "l-own", pr: 11}),
            (ask("a-del"; "release") + {question: "push the OTA release", lane: "l-del", askedAt: $a5}),
            (ask("a-wk"; "merge") + {worker: "w-ask", pr: "acme-app#17", files: ["src/components/Card.tsx"]}),
            (ask("a-nc"; "code") + {question: "split the card?", worker: "w-nc", files: [], noCode: true, issue: 5}),
            (ask("a-url"; "merge") + {pr: "https://github.com/AcmeOrg/acme-app/pull/22"}),
            (ask("a-fu"; "owner") + {question: "follow-up fu-1", lane: "dev-sweeper", followUp: "fu-1"})],
     queue: {items: [{id: "q1", lane: "dev-q", state: "queued"}]}, lanes: {"dev-r": {queue: ["x"]}},
     freeze: ($fz // {state: "off", ttl: $ttl, window: "w0"})}' > "$d/led.json"
}
