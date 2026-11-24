# Input contract: the typed input boundary

Schema name `cm.input/v1`. Code: `scripts/input-view.jq` (the typed view and the decisions), `scripts/jdupkeys` (the repeated-key scan), the `cm_input_*` and
`cm_ledger_schema_version` functions in `scripts/lib.sh`, the state lists and the closed type table (`CM_STATES_*`, `CM_JQ_NAME_DEFS`) in `scripts/lib.sh`, and the
dry-run manifest `scripts/input-migrate-manifest.sh`. Tracking issue: ainb-toolkit#209.

This is a precursor. It carries the boundary, this contract and the tests that prove it. It changes no existing program: the readers in `teardown.sh`,
`resume.sh`, `roster.sh`, `lane-health.sh` and the rest still read the ledger with their own jq idioms. Moving them onto the boundary is a later change, one program at a time.

## 1. Why

A ledger value of the wrong type must never read as "nothing there". Today a reader that writes `(.standing // false)`, `.state // "running"`, `.host // "local"` or
`(.issue // .issueUrl) == null` reads a `null` row, `false`, `0`, `""`, `" "`, an object where a string belongs, or a misspelt enum as ABSENT, and then takes the absent
default: a protection that was meant to hold is skipped, or a permission that was never given is assumed. The boundary turns raw input into typed members whose every
field carries a status, and a program acts only on an exact `permit: true`.

```text
┌───────────────┐   ┌──────────────────────┐   ┌─────────────────────┐   ┌───────────────┐
│ ledger.json   │──▶│ input-view.jq        │──▶│ typed view          │──▶│ decision      │
│ live replies  │   │ (one read, one scan) │   │ member.fields.<f>   │   │ permit:true   │
└───────────────┘   └──────────────────────┘   │ {value,status,why}  │   │ + snapshot    │
                                               └─────────────────────┘   └───────┬───────┘
                                                                                 ▼
                                                          a program acts only on permit:true
```

## 2. Shape

- A **field** is `{value, status, reason}`; `status` is `missing` (key absent or `null`), `valid`, or `invalid` (wrong type, blank text, unknown enum, a value with a control character).
- A **member** is one row of a container: `{sourcePath, key, index, rowBad, fields}`. No member is dropped. A row that is not an object, a key with a control character, a repeated key
  inside the row, an ask with no usable or a repeated id: `rowBad` names why, the member is counted and named, and it holds only what it might be (rule 5).
- The **view** (`iv_view`) holds the members of `workers`, `asks`, `followUps`, `lanes`, `hosts` and `deployWindows`, the status of each container (a container of the wrong type is named, never read as empty), the
  `schemaVersion`, `legacy` (true while the version is below 2), and the list of every issue.
- A **decision** (`iv_decide`, `cm_input_decide`) is `{action, target, permit, reasons[], snapshot}`. `permit` is true only when every gate passed. `snapshot` is the readable fields the decision
  relied on; `cm_input_revalidate` decides again just before the action and refuses when `permit` or the snapshot changed.
- Actions: `sleep`, `nudge`, `resume`, `capacity_kill`, `teardown`. An unknown action is refused.
- A **live reply** (`cm_input_live terminals|worktrees`, a CLI answer read at the moment of action) is always ONE envelope. A list is `complete` only when the reply is an object, `ok` is not false,
  `result` is an object, the list is an array, `truncated` is absent or exactly `false`, `totalCount` is absent or a whole number that fits in the rows read, and no key is written twice. A terminal is
  `agent` (a named agent runs), `shell` (the key is absent: a plain shell) or `unknown` (any other value: never read as a shell). A screen that is not text is unknown, never an empty screen.

## 3. Roles

A field's ROLE fixes what an invalid value does.

| role | meaning | an INVALID value |
|---|---|---|
| PROT | a protection: "do not act, keep this" (standing, an open follow-up, a parent chain, a lane lead, an open ask, `beadsEpic`, `epicConflict`, an asleep worker) | HOLD: the scope it covers stays held and the report names the unreadable field |
| ID | an identity used to match one thing to another (host, path, worktree id, worker id, lane, ask id, handle, pr or issue number) | WIDEN, BOUNDED inside a PROT record (rule 5); REFUSE inside a PERM record; never a default |
| PERM | a permission: its truth lets an action run (a state that may be resumed, a decision `approved`, `usedAt` null, standing for the action) | REFUSE: the action does not run |
| DISP | display, time, counters | REPORT "unreadable"; never print 0 or a default as if it had been read |

## 4. Rules

1. **ABSENT versus INVALID.** An absent key (missing or `null`) takes a default only where section 5 lists one, and only while `schemaVersion` is below 2. **An invalid value never takes the ABSENT default, in any version.** At version 2 or more an absent field is unknown.
2. **Tri-state.** `standing` is `true`, `false` or `unknown`; `state` is a known state or `unknown`. `unknown` refuses the actions that need standing AND the actions that need not-standing, the live-only actions (nudge, resume) AND the dead-only ones (teardown).
3. **Roles follow the use**, not the field: anything that feeds a nudge, a relaunch, a sleep or a write is PERM.
4. **An ID inherits its record's role.** Inside a PERM record (an ask's host, path or worker) an invalid id narrows to nothing, so the action is refused. Inside a PROT record it widens.
5. **Bounded widening: one bad member blocks only what it might be.** A readable key, host or path narrows a hold. A lane named by a follow-up or an ask counts as readable only when it is a lane that exists (a key of `lanes` or the lane of a worker row): a near spelling (`L` for `l`, `l `) is not a lane, narrows nothing, and the item holds.
   A parent with no row is the root of its own family and is reported (removing a row is normal lifecycle). A worker is PLACED only when its parent chain reaches a root through readable rows; a chain through an unreadable row, a loop or itself is unplaced however deep, and an unplaced worker's open follow-ups hold. A follow-up whose `worker` is unreadable, or names no worker row exactly (`"T"` for `t`), holds when its lane may be the lane of the target, of anything below it, or of any row that cannot be placed. A lane `lead` that names no worker row holds the teardown of the workers that may belong to that lane. A teardown of a worker that is its own parent, or sits in or below a loop, is held. The walk visits each row once, so a loop cannot stall a decision.
6. **Asks.** An ask HOLDS the teardown of a worker while it is open (state `open`, `in-progress`, absent or unreadable: only `answered`, `decided` and `closed` let go) and is about that worker. A readable `worker` names it (equal holds, different does not); else its lane, `pr` and `path` are compared with the worker's, a tie field that is unreadable or that the worker has no readable counterpart for MAY be the tie, and an ask that names nothing readable at all may be about anyone. An ask row that is not an object, or in which a key is written twice, holds every teardown. An ask with no usable id, or an id another ask has, is `rowBad`: it holds what it can still be tied to and grants nothing. Ask `state`, `kind` (read trimmed and lower case) and `decision` are exact enums.
7. **`hosts.<h>.reachable`** in the ledger is DISP (a stale copy of the last discover); live reachability comes only from discover or ssh.
8. **Repeated keys and numbers.** `scripts/jdupkeys` (python3) scans the document itself, at ANY depth and whatever the values, because jq keeps only the last of two equal keys. The ledger is read ONCE into a private snapshot and the parse and the scan use those same bytes; a scan that fails is an unreadable ledger and every decision refuses. `NaN`, `Infinity`, a float that overflows a double, an integer too large for a double, and a LONE surrogate escape (jq reads it as U+FFFD, so two keys that differ only there would hide a repeat) make the document unreadable; a surrogate pair is one character and is accepted. WHOLE NUMBERS are decided from the exact decimal token, not from the double jq makes of it: `1.0000000000000001` makes the document unreadable, `1.0`, `1e0` and `7.000` are the numbers 1 and 7. A repeated member key makes the member `rowBad`; a repeated container key makes the container invalid; a repeated `schemaVersion` makes the version invalid. The same scan covers a live reply: a key written twice, a copy that exits non-zero or a scan that fails makes the reply incomplete, never complete. python3 is required.
9. **Revalidation.** A decision is decided again right before the action (`cm_input_revalidate`) and compared byte for byte on action, target and snapshot: a target that differs only by a trailing newline is another target. The action that runs only under the locks of the ledger and of the action, and holds both through the command, is not part of this change (section 7).
10. **One single-line predicate** (`iv_oneline` in `input-view.jq`, `cm_name_ok` in `lib.sh`): no control character (`\p{Cc}`: TAB, VT, NUL, ESC, NEL U+0085 ...), no U+2028, no U+2029. It sits under EVERY single-line kind: a name, id, lane, parent, terminal, worktree id, host, path, each entry of a list, the part of an issue URL after the number, and every object KEY (a worker key). A key that fails it makes the member `rowBad`. Such a character is what a command substitution (it drops NUL and a trailing newline), a line-per-row list or `read` loses, trims or splits on, so two names that differ only by one would be read as the same row. The one free-text field is a live worktree `comment` (kind `text`: non-blank, may span lines). BLANK is decided by Unicode category (separators, controls, format characters) plus U+180E, U+034F, U+115F, U+1160, U+3164, U+FFA0, U+2800 and the variation selectors, so a name made only of invisible code points is invalid.
11. **A closed type table** (`cm_row_types`, `cm_live_types`, `cm_health_types` in `lib.sh`, checked by `cm_row_typed_ok`; `cm_row_fields_ok` adds the control-character test): every field a script reads from a worker row, its `live` object and its `health` object, with the one JSON type it may have. Absent or `null` is allowed; any other type makes the row UNKNOWN (`jq -r` prints an array as its text, a joining reader joins it, the text `"true"` is not true). A TIME is text or a number. The control-character test covers every string field of the table, derived from the table itself, so a field added to it is covered without a second list.
12. **Enums are exact.** A state outside `CM_STATES_ALL` (a legacy spelling reads as its state) is unknown. Lane states are `absent`, `spawning`, `running`, `idle`, `draining`, `gone`; a lane state outside the list holds the workers that may belong to the lane. Deploy window states are `pending`, `rails-check`, `staging`, `validating`, `prod`, `done`, `skipped`, `stopped`. A ledger ask kind outside the documented kinds is invalid.

## 5. Field dictionary (type, ABSENT default, role, what INVALID does)

"legacy" is the default taken for an ABSENT key only while `schemaVersion` is below 2. At version 2 or more an absent field is unknown.

| field | type | ABSENT default | role | INVALID |
|---|---|---|---|---|
| `workers` | object of rows | none | PROT | the container is invalid: every decision refuses |
| `workers.<id>` (row) | object; key is single-line text | none | PROT+ID | `rowBad`, held, named |
| `.host` | single-line text, no space, `local` exactly lower case | legacy: an absent KEY is `local`; `null`, `false`, `0`, `""`, blank, `{}`, `[]`, `"LOCAL"`, `" local "` are INVALID | ID | PERM uses REFUSE, PROT uses bounded WIDEN; never `// "local"` |
| `.path` (aliases `worktree`, `worktreePath`) | absolute path on one line, no `..` segment (spaces allowed) | canonical `path` first; an alias counts ONLY when `path` is absent; all absent is missing | ID | an invalid canonical, an invalid alias, or aliases naming different places are invalid: HOLD. Compared lexically after collapsing `//`, `.` segments and the trailing slash |
| `.state` | exact enum, `CM_STATES_ALL` (legacy spelling read as its state) | legacy: `running`; at v2 unknown | PROT+PERM | tri-state (rule 2) |
| `.standing` | boolean | legacy per action: nudge, resume, capacity_kill read `false`; sleep, teardown read `unknown`; at v2 unknown | PROT | tri-state (rule 2) |
| `.parent` | single-line text or null | absent or null: no parent | ID+PROT | the row is unplaceable (rule 5); refuses teardown only |
| `.lane`, `.worktreeId`, `.terminal` | single-line text | absent: no value | ID | unreadable widens, bounded |
| `.beadsEpic` | single-line text or null | none | PROT | refuses teardown |
| `.epicConflict` | list of single-line text | `[]` | PROT | a non-list refuses teardown; a non-empty list refuses teardown |
| `.pr` | positive whole number | absent: no pr | ID | invalid |
| `.live`, `.health` and the rest of the type table | see rule 11 | absent: never checked | DISP | the row is UNKNOWN |
| `asks` | list of objects | `[]` while legacy | PROT+PERM | a non-list holds every teardown; at v2 a MISSING `asks` refuses teardown |
| `asks[].id` | single-line text, unique | none | ID | `rowBad` (rule 6) |
| `asks[].state`, `.kind`, `.decision` | exact enums (kind: `code design test scope product release deploy merge credentials migration auth payments prod-data teardown owner secrets remove-standing accept-unmerged-beads merge-gate-override`; decision: `approved declined report-only`) | state absent: unknown, holds | PERM | an unknown value is invalid |
| `asks[].host`, `.path`, `.worker`, `.lane`, `.pr`, `.issue`, `.usedAt`, `.askedAt`, `.timeoutAt` | host, path, worker id, lane, positive whole number, ISO UTC time | `usedAt` null is unused | ID/PERM | inside a PERM record an invalid id REFUSES |
| `followUps` | list of objects | `[]` while legacy | PROT | a non-list holds every teardown; at v2 a MISSING `followUps` refuses teardown |
| `followUps[].id`, `.worker`, `.lane`, `.owner` | single-line text | none | ID | an unattributable follow-up holds by lane (rule 5) |
| `followUps[].state` | text; exactly `done` closes it, anything else is open | absent: open | PROT | never closed by `closedAt` |
| `followUps[].issue`, `.issueUrl` | positive whole number below 1000000000; `https://github.com/<owner>/<repo>/(issues\|pull)/<n>` (ASCII allow-list, one segment each) | absent: not escalated | PROT | ESCALATED means a valid `issue` OR a valid `issueUrl`. `0`, negatives, `"#12"`, `"12"` and `"none"` are NOT an escalation (the manifest lists `"#12"` and `"12"` so they can be written as numbers) |
| `lanes` | object of rows | `{}` while legacy | PROT | a non-object holds every teardown; at v2 a MISSING `lanes` refuses teardown |
| `lanes.<lane>.lead` | single-line text or null | none | PROT+ID | invalid, or naming no worker row, holds the workers of that lane |
| `lanes.<lane>.state` | enum (rule 12) | absent | PROT | rule 12 |
| `hosts.<h>.hostname`, `.reachable`, `.maxWorkers` | text, boolean, positive whole number | absent | ID/DISP | reported |
| `deployWindows` | list of objects (`id`, `state`, `worker`) | `[]` | PROT | a bad entry is listed in the manifest |
| `freeze` | `{state: on\|off, ttl: ISO time, window: text}` | absent: off | PROT | listed in the manifest as a container issue |
| `schemaVersion` | positive whole number below 1000000 | absent or `null`: 1 (legacy) | ID | present and invalid (text, 0, negative, fraction, `true`, object, list, written twice) is invalid in EVERY version |

## 6. Decisions

Every decision first requires: a readable ledger, a valid `workers` container, a worker row that exists and is readable, a valid `schemaVersion`, a non-blank host the decision is for, a worker on that host, a readable `path`, a known `state`, and a known `standing`.

| action | also requires |
|---|---|
| `nudge` | state `running`, `stuck` or `blocked-on-owner` |
| `resume` | `standing` true, and a live state as above |
| `sleep` | `standing` true, and a live state as above |
| `capacity_kill` | `standing` not true, and a live state or `done` or `retired` |
| `teardown` | `standing` not true; state not `asleep`; `parent`, `beadsEpic`, `epicConflict` readable and no conflict recorded; the containers `followUps`, `lanes` and `asks` readable and (at version 2 or more) present; the worker placed in its family; no open unescalated follow-up on it or anything below it; no lane it leads and no unreadable lane state that may be its own; no open ask about it |

## 7. Numbers

An ask, a follow-up issue, a `pr`, a `maxWorkers` and a `schemaVersion` are whole numbers of at least 1 (0, 00 and negatives are no number) and below 1000000000 (the version below 1000000), decided from the exact decimal token (rule 8).

## 8. Migration

- The ledger gets `schemaVersion`. Readers apply TODAY'S legacy defaults for an ABSENT key only while the version is below 2, so a well-typed legacy row keeps its behaviour. An INVALID value holds or refuses in every version. At version 2 or more an absent field is unknown.
- `scripts/input-migrate-manifest.sh [--json] [ledger]` is a READ-ONLY dry run: it lists what must be settled before a later stamp may set version 2. Per worker: the keys missing (`path`, `state`, `standing`, `host`), a path alias to move to `path`, a legacy state spelling, invalid fields (including a present field of the closed type table of the wrong type or with a control character), unreadable rows, a row with a terminal and no path, a parent chain that cannot be placed. Also: follow-ups whose `issue` is text, a repeated follow-up id, asks with no usable id, EVERY unreadable, invalid or incomplete member of `asks`, `followUps`, `lanes`, `hosts` and `deployWindows` (a follow-up needs `id`, `worker`, `lane`, `owner`, `state`; an ask or a deploy window needs `id` and `state`), a required container (`workers`, `asks`, `followUps`, `lanes`) that is absent or null, a `freeze` or `health` of the wrong shape, and every repeated key. A parent with no row is listed as `danglingParents` and does not make the manifest unclean. It writes nothing: no ledger write, no lock, no backup. Exit 0 when `clean`, 1 when there is something to settle, 2 when the ledger cannot be read.
- No automatic stamping. A stamp verb, when it is added, writes through `cm_ledger_write` only for rows the owner verified, never a blanket `running` or `standing: false`, and sets version 2 only when the manifest is clean.

## 9. Not in this change

These are the pieces of a fuller version of the boundary that the template does not carry yet, each needing something the template does not have:

- the revalidating action wrapper (`cm_input_act`): it holds the lock of the actual input ledger and an action lock and renews a lease on both; it needs the lock layer (owner tokens bound to the shell, a lease, a portable canonical ledger path), which `lib.sh` here does not have;
- the exact-name readers (`cm_read_name` and the by-path and by-id handle writers that use it): they need the host-identity helpers (which names are this host) that the template does not have;
- the per-read inventory (every read of every program, its role and what an invalid value does today) and the check that every read is listed: it has to be written against the scripts of this skill;
- moving the template's programs onto the boundary.

## 10. Tests

| test | what |
|---|---|
| `scripts/test/input-types.sh` | the state lists and the closed type table |
| `scripts/test/input-dupkeys.sh`, `scripts/test/schema-version.sh` | the repeated-key scan and the version read |
| `scripts/test/input-view.sh` | the view, the legacy defaults, tri-state, holds, duplicate keys, live replies, revalidation, single-line and blank text |
| `scripts/test/input-parity.sh` | for well-typed input the boundary decides exactly as today's readers do |
| `scripts/test/input-matrix.sh` | every bad value of every modelled field refuses the action it gates, and the same grid fails against a reader written with the usual `//` idioms (`MATRIX_LEGACY=1`) |
| `scripts/test/input-migrate.sh` | the manifest lists what it must, writes nothing, and its exit codes |
| `scripts/test/input-gate.sh` | the hard cases: unreadable middle rows, loops, repeated keys inside a row, near-spelt lanes, numbers, trailing newlines, URL allow-list, path aliases |
