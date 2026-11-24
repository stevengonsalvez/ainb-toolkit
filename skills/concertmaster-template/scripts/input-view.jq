# input-view.jq: the typed input boundary of the concertmaster (schema cm.input/v1).
#
#   raw documents (ledger.json, classify.json, discover.json, a CLI reply read at the moment of action)
#     -> this file -> a TYPED VIEW (members whose fields carry a status) -> DECISIONS {action,target,permit,reasons,snapshot}
#     -> a bash adapter (lib.sh: cm_input_view, cm_input_decide, cm_input_revalidate) that acts only on permit:true.
#
# The contract: references/input-contract.md (every read, its role, its ABSENT default, what an INVALID value must do).
#
# Use:  jq -L "$SCRIPTS" --argjson cfg "$(cm_input_cfg)" 'include "input-view"; iv_view(.; $cfg)' ledger.json
#
# RULES (the whole policy; each function below is one of them):
#   1. A field is {value, status, reason}. status is missing (key absent or null), valid, or invalid (wrong type, blank text, unknown enum).
#      An INVALID value never takes the ABSENT default. null counts as absent: it takes the legacy default only while schemaVersion < 2, and is unknown from 2 on.
#   2. No member is dropped. A row that is not an object is a member with rowBad set; a null member is named, counted and holds.
#   3. A field's ROLE fixes what invalid does: a PROTECTION holds its scope; an IDENTITY widens, BOUNDED (a readable key, host or path narrows
#      the hold; a dangling parent is the root of its own family); a PERMISSION refuses the action; display is reported, never defaulted.
#   4. standing and state are TRI-STATE: standing true|false|"unknown"; state a known enum value or "unknown". "unknown" refuses both the
#      actions that need standing and the ones that need not-standing, and both the live-only and the dead-only actions.
#   5. While the ledger schemaVersion < 2 (legacy), an ABSENT key (never an invalid one) takes the legacy default carried in the field's
#      `legacy` member; a decision uses it only where today's program does (iv_legacy_standing). At schemaVersion >= 2 absent = unknown.
#   6. A decision is {action, target, permit, reasons[], snapshot}. permit is true only when every gate passed. The snapshot is the readable
#      fields the decision relied on: the adapter re-runs the decision just before the action and refuses if permit or snapshot changed.
#
# cfg (from lib.sh, one source of truth): {states:[...], dead:[...], noresume:[...], legacy:{<spelling>:<state>}}

def iv_schema: "cm.input/v1";

# ---- fields ------------------------------------------------------------------------------------------------------------------------
def iv_ok($v): {value: $v, status: "valid", reason: null};
def iv_miss: {value: null, status: "missing", reason: null};
def iv_bad($why): {value: null, status: "invalid", reason: $why};
# ONE blank test for every "non-blank text" check. The regex \S counts invisible code points (U+200B, U+FEFF, U+2063, U+00AD, ...) as text, so a field made only
# of them read as a real name and a parent of it as a dangling parent. iv_blank is the body of a character class that matches every BLANK character, by Unicode
# category rather than a hand list: separators (Z: Zs, Zl, Zp), controls (Cc), format characters (Cf: U+00AD, U+200B..U+200F, U+202A..U+202E, U+2060..U+2064,
# U+FEFF ...), white space, and the code points that draw nothing but are not in those categories (U+180E, U+034F, U+115F, U+1160, U+3164, U+FFA0, U+2800 (the Braille blank) and the
# variation selectors U+FE00..U+FE0F). iv_nonc is a one-character class of everything else, for the "no blank anywhere" tests.
def iv_blank: "\\p{Z}\\p{Cc}\\p{Cf}\\s\u180E\u034F\u115F\u1160\u3164\uFFA0\uFE00-\uFE0F\u2800";
def iv_nonc: "[^" + iv_blank + "]";
# a GitHub URL is https://github.com/<owner>/<repo>/(issues|pull)/<n>, ONE path segment each, written as an ASCII ALLOW-LIST (never "anything but a bad
# character"): an owner is [A-Za-z0-9][A-Za-z0-9-]{0,38}; a repo is [A-Za-z0-9._-]{1,100} and not only dots ("." and ".." are directory names). A "#" or "?"
# is allowed only after the number, as the optional suffix. A ".git" suffix on the repo is accepted (a documented limit).
def iv_gh_owner: "[A-Za-z0-9][A-Za-z0-9-]{0,38}";
def iv_gh_repo: "(?!\\.+/)[A-Za-z0-9._-]{1,100}";
# what may follow the number: a "#" or "?" then URL characters only (RFC 3986 unreserved, reserved and the percent sign), never a control or blank character
def iv_url_tail: "[A-Za-z0-9._~:/?#@!$&'()*+,;=%\\[\\]-]*";
def iv_nonblank: type == "string" and test(iv_nonc);
# ONE single-line predicate, and every single-line kind is built on it (str, strlist, host, path, the issue-URL suffix, every object key): a string is on one
# line when it holds no control character (\p{Cc}: TAB, VT, NUL, ESC, NEL U+0085 ...) and no line or paragraph separator (\p{Zl} U+2028, \p{Zp} U+2029).
# Such a character is what a program that moves or compares a name (a shell variable, a command substitution, a line-per-row list) trims, drops or splits on,
# so two names that differ only by one of them would be read as the same. iv_text is non-blank text on one line (a name, an id, a lane, a parent, a path, a
# host). A field that is free text (a worktree comment) uses iv_nonblank alone.
def iv_oneline: type == "string" and (test("\\p{Cc}|\\p{Zl}|\\p{Zp}") | not);
def iv_text: iv_nonblank and iv_oneline;
# a path compared lexically: repeated slashes collapse, "." segments and the trailing slash go ("/w//a/./" is "/w/a"). A ".." segment is not resolved here: a path
# that has one is invalid (iv_check kind path), so it is never matched by a guess and an ask about it holds
def iv_normp: if type == "string" then (split("/") | map(select(. != "" and . != ".")) | "/" + join("/")) else . end;
def iv_state_norm($cfg): if type == "string" then ($cfg.legacy[.] // .) else . end;

# a worker host is valid text with no space; "local" is exactly lower case ("LOCAL" and " local " are INVALID, never "local")
def iv_time_ok: type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z\\z");
def iv_host_ok: iv_oneline and test("\\A" + iv_nonc + "+\\z") and (if ascii_downcase == "local" then . == "local" else true end);

# iv_check($kind; $cfg): the value is present and not null; kinds: str text bool posint time path host state strlist ghurl enum:<a,b,c>
def iv_check($kind; $cfg):
  . as $v
  | if $kind == "str" then (if iv_text then iv_ok($v) else iv_bad("not non-blank text (" + ($v | type) + ")") end)
    elif $kind == "text" then (if iv_nonblank then iv_ok($v) else iv_bad("not non-blank text (" + ($v | type) + ")") end)
    elif $kind == "bool" then (if type == "boolean" then iv_ok($v) else iv_bad("not a boolean (" + ($v | type) + ")") end)
    elif $kind == "posint" then (if type == "number" and . >= 1 and . == floor and . < 1000000000 then iv_ok($v) else iv_bad("not a positive whole number") end)
    elif $kind == "time" then (if iv_time_ok then iv_ok($v) else iv_bad("not an ISO UTC time") end)
    elif $kind == "path" then (if iv_text and test("\\A/") and (test("(^|/)\\.\\.(/|$)") | not) then iv_ok($v) else iv_bad("not an absolute path") end)
    elif $kind == "host" then (if iv_host_ok then iv_ok($v) else iv_bad("not a plain host name (blank, spaced, wrong-case local, or not text)") end)
    elif $kind == "state" then
      (iv_state_norm($cfg)) as $n
      | (if ($n | type) == "string" and (($cfg.states | index($n)) != null) then iv_ok($n) | . + {spelling: $v} else iv_bad("not a known state") end)
    elif $kind == "strlist" then (if type == "array" and all(.[]; iv_text) then iv_ok($v) else iv_bad("not a list of non-blank text") end)
    elif $kind == "ghurl" then (if type == "string" and test("\\Ahttps://github\\.com/" + iv_gh_owner + "/" + iv_gh_repo + "/(issues|pull)/[1-9][0-9]{0,8}([#?]" + iv_url_tail + ")?\\z") then iv_ok($v) else iv_bad("not a GitHub issue or pull request URL") end)
    elif ($kind | startswith("enum:")) then
      ($kind | ltrimstr("enum:") | split(",")) as $set
      | (if type == "string" and (($set | index($v)) != null) then iv_ok($v) else iv_bad("not one of " + ($set | join("|"))) end)
    else error("iv_check: unknown kind " + $kind) end;

# iv_get($row; $key; $kind; $cfg): one field of one row
def iv_get($row; $k; $kind; $cfg):
  if ($row | type) != "object" or ($row | has($k) | not) or $row[$k] == null then iv_miss
  else ($row[$k] | iv_check($kind; $cfg)) end;

# worker path with its two legacy aliases: `worktree` and `worktreePath` count ONLY when the canonical `path` is absent; an invalid canonical,
# or aliases that name different places, are invalid (the row is held, never matched by a guess)
def iv_path($row; $cfg):
  iv_get($row; "path"; "path"; $cfg) as $c
  | ([ "worktree", "worktreePath" ] | map(. as $k | iv_get($row; $k; "path"; $cfg) | . + {key: $k}) | map(select(.status != "missing"))) as $al
  | if $c.status == "invalid" then $c
    elif $c.status == "valid" then
      (if any($al[]; .status == "invalid" or (.value | iv_normp) != ($c.value | iv_normp)) then iv_bad("path conflicts with, or an alias of it is not, the same path") else $c + {source: "path"} end)
    elif ($al | length) == 0 then iv_miss
    elif any($al[]; .status == "invalid") then iv_bad("a path alias is not an absolute path")
    elif (($al | map(.value | iv_normp) | unique | length) > 1) then iv_bad("path aliases name different places")
    else iv_ok($al[0].value) | . + {source: $al[0].key} end;

# standing: true | false | "unknown" (absent, null or not a boolean)
def iv_standing($row; $cfg):
  iv_get($row; "standing"; "bool"; $cfg)
  | if .status == "valid" then . else {value: "unknown", status: .status, reason: (.reason // "standing is absent")} end;

# state: a known enum value (a legacy spelling is read as its state) or "unknown"
def iv_state($row; $cfg):
  iv_get($row; "state"; "state"; $cfg)
  | if .status == "valid" then . else {value: "unknown", status: .status, reason: (.reason // "state is absent")} end;

# the legacy defaults a missing key takes while schemaVersion < 2, one per action for standing because today's programs differ:
# the resume, runtime-check and capacity readers treat an absent standing as not standing (`standing == true` is false); teardown, sleep and classify
# refuse it (references/ledger.md: null or missing is "standing state unknown")
def iv_legacy_standing: {nudge: false, resume: false, capacity_kill: false, sleep: "unknown", teardown: "unknown"};

# ---- members -----------------------------------------------------------------------------------------------------------------------
def iv_member($src; $key; $idx; $row; mk):
  if ($row | type) != "object"
  then {sourcePath: $src, key: $key, index: $idx, rowBad: ("the row is " + ($row | type) + ", not an object"), fields: {}}
  elif ($key != null and ($key | iv_text | not))
  then {sourcePath: $src, key: $key, index: $idx, rowBad: "the key is not non-blank text on one line (a control character, or a line or paragraph separator, in a name)", fields: {}}
  else {sourcePath: $src, key: $key, index: $idx, rowBad: false, fields: ($row | mk)} end;

def iv_worker_fields($cfg):
  . as $r
  | {
      host: (if ($r | has("host")) and $r.host == null then iv_bad("host is null (only an absent key defaults)")
             else (iv_get($r; "host"; "host"; $cfg) | if .status == "missing" then . + {legacy: "local"} else . end) end),
      path: iv_path($r; $cfg),
      pr: iv_get($r; "pr"; "posint"; $cfg),
      worktreeId: iv_get($r; "worktreeId"; "str"; $cfg),
      state: (iv_state($r; $cfg) | if .status == "missing" then . + {legacy: "running"} else . end),
      standing: (iv_standing($r; $cfg) | if .status == "missing" then . + {legacy: iv_legacy_standing} else . end),
      parent: iv_get($r; "parent"; "str"; $cfg),
      lane: iv_get($r; "lane"; "str"; $cfg),
      beadsEpic: iv_get($r; "beadsEpic"; "str"; $cfg),
      epicConflict: iv_get($r; "epicConflict"; "strlist"; $cfg),
      terminal: iv_get($r; "terminal"; "str"; $cfg)
    };

# the enums of an ask, exactly as references/ledger.md writes them (a spelling outside the list is invalid, never a valid state)
def iv_ask_states: ["open", "answered", "in-progress", "decided", "closed"];
def iv_ask_kinds: ["code", "design", "test", "scope", "product", "release", "deploy", "merge", "credentials", "migration", "auth", "payments", "prod-data", "teardown", "owner", "secrets", "remove-standing", "accept-unmerged-beads", "merge-gate-override"];
def iv_ask_decisions: ["approved", "declined", "report-only"];
def iv_ask_enum($set): if .status == "valid" then (if (.value | IN($set[])) then . else iv_bad("not one of " + ($set | join("|"))) end) else . end;

def iv_ask_fields($cfg):
  . as $r
  | {
      id: iv_get($r; "id"; "str"; $cfg),
      state: (iv_get($r; "state"; "str"; $cfg) | iv_ask_enum(iv_ask_states)),
      kind: (iv_get($r; "kind"; "str"; $cfg) | if .status == "valid" then iv_ok(.value | gsub("^\\s+|\\s+$"; "") | ascii_downcase) else . end | iv_ask_enum(iv_ask_kinds)),
      decision: (iv_get($r; "decision"; "str"; $cfg) | iv_ask_enum(iv_ask_decisions)),
      usedAt: (if ($r | type) == "object" and ($r | has("usedAt")) and $r.usedAt != null then ($r.usedAt | iv_check("time"; $cfg)) else iv_miss end),
      host: iv_get($r; "host"; "host"; $cfg),
      path: iv_get($r; "path"; "path"; $cfg),
      worker: iv_get($r; "worker"; "str"; $cfg),
      lane: iv_get($r; "lane"; "str"; $cfg),
      pr: iv_get($r; "pr"; "posint"; $cfg),
      issue: iv_get($r; "issue"; "posint"; $cfg),
      askedAt: iv_get($r; "askedAt"; "time"; $cfg),
      timeoutAt: iv_get($r; "timeoutAt"; "time"; $cfg)
    };

def iv_followup_fields($cfg):
  . as $r
  | {
      id: iv_get($r; "id"; "str"; $cfg),
      worker: iv_get($r; "worker"; "str"; $cfg),
      lane: iv_get($r; "lane"; "str"; $cfg),
      owner: iv_get($r; "owner"; "str"; $cfg),
      state: iv_get($r; "state"; "str"; $cfg),
      issue: iv_get($r; "issue"; "posint"; $cfg),
      issueUrl: iv_get($r; "issueUrl"; "ghurl"; $cfg)
    };

def iv_lane_fields($cfg):
  . as $r
  | { state: iv_get($r; "state"; "enum:absent,spawning,running,idle,draining,gone"; $cfg),
      lead: iv_get($r; "lead"; "str"; $cfg) };

def iv_host_fields($cfg):
  . as $r
  | { hostname: iv_get($r; "hostname"; "str"; $cfg),
      reachable: iv_get($r; "reachable"; "bool"; $cfg),
      maxWorkers: iv_get($r; "maxWorkers"; "posint"; $cfg) };

def iv_window_fields($cfg):
  . as $r
  | { id: iv_get($r; "id"; "str"; $cfg),
      state: iv_get($r; "state"; "enum:pending,rails-check,staging,validating,prod,done,skipped,stopped"; $cfg),
      worker: iv_get($r; "worker"; "str"; $cfg) };

# a container of members: an object of rows (`obj`) or a list of rows (`arr`). A container of the wrong type is named, never read as empty.
def iv_container($doc; $name; $shape; mk; $cfg):
  ($doc | if type == "object" then .[$name] else null end) as $c
  | if ($doc | type) != "object" or ($doc | has($name) | not) or $c == null then {name: $name, status: "missing", reason: null, members: []}
    elif $shape == "obj" and ($c | type) == "object"
      then {name: $name, status: "valid", reason: null, members: [ $c | to_entries[] | iv_member($name + "." + .key; .key; null; .value; mk) ]}
    elif $shape == "arr" and ($c | type) == "array"
      then {name: $name, status: "valid", reason: null, members: [ $c | to_entries[] | iv_member($name + "[" + (.key | tostring) + "]"; null; .key; .value; mk) ]}
    else {name: $name, status: "invalid", reason: ($name + " is " + ($c | type) + ", not " + (if $shape == "obj" then "an object" else "a list" end)), members: []} end;

# an ask with no usable id, or an id another ask has, is rowBad: it holds the lane or PR it can still be tied to and grants nothing
def iv_ask_check:
  ([ .[] | select(.rowBad == false and .fields.id.status == "valid") | .fields.id.value ] | group_by(.) | map(select(length > 1) | .[0])) as $dups
  | map(if .rowBad != false then .
        elif .fields.id.status != "valid" then .rowBad = "the ask has no usable id (" + (.fields.id.reason // "missing") + ")"
        elif (.fields.id.value | IN($dups[])) then .rowBad = "ask id " + .fields.id.value + " is used by more than one ask"
        else . end);

def iv_version($doc):
  ($doc | if type == "object" then .schemaVersion else null end) as $v
  | if $v == null then {value: 1, status: "missing", reason: null}
    elif ($v | type) == "number" and $v >= 1 and $v == ($v | floor) and $v < 1000000 then {value: $v, status: "valid", reason: null}
    else {value: null, status: "invalid", reason: "schemaVersion is not a positive whole number"} end;

# The two top-level objects the manifest also checks: freeze ({state on|off, ttl ISO time, window text}, absent = off) and health (an object, absent = not checked). A present
# value of the wrong shape, or an unknown freeze state, is an issue (kind container, so it lists in the manifest and keeps it from being clean).
def iv_scalar_issues($doc):
  [ (if ($doc | type) == "object" then
       ( ($doc.freeze) as $f
         | if $f == null then empty
           elif ($f | type) != "object" then {sourcePath: "freeze", kind: "container", reason: "freeze is not an object"}
           elif ($f.state | type) != "string" or ($f.state | IN("on", "off") | not) then {sourcePath: "freeze", kind: "container", reason: "freeze.state is not on or off"}
           elif $f.ttl != null and ($f.ttl | iv_time_ok | not) then {sourcePath: "freeze.ttl", kind: "container", reason: "freeze.ttl is not an ISO UTC time"}
           elif $f.window != null and ($f.window | type) != "string" then {sourcePath: "freeze.window", kind: "container", reason: "freeze.window is not text"}
           else empty end ),
       ( ($doc.health) as $h
         | if $h == null then empty
           elif ($h | type) != "object" then {sourcePath: "health", kind: "container", reason: "health is not an object"}
           else empty end )
     else empty end) ];

# iv_view($doc; $cfg): the envelope. legacy is true while schemaVersion < 2 (an INVALID version is not legacy: nothing defaults).
def iv_view($doc; $cfg):
  iv_version($doc) as $ver
  | ($ver.status == "missing" or ($ver.status == "valid" and $ver.value < 2)) as $legacy
  | [ iv_container($doc; "workers"; "obj"; iv_worker_fields($cfg); $cfg),
      iv_container($doc; "asks"; "arr"; iv_ask_fields($cfg); $cfg),
      iv_container($doc; "followUps"; "arr"; iv_followup_fields($cfg); $cfg),
      iv_container($doc; "lanes"; "obj"; iv_lane_fields($cfg); $cfg),
      iv_container($doc; "hosts"; "obj"; iv_host_fields($cfg); $cfg),
      iv_container($doc; "deployWindows"; "arr"; iv_window_fields($cfg); $cfg) ]
    | map(if .name == "asks" then .members |= iv_ask_check else . end) as $cs
  | ($cs | map({key: .name, value: .}) | from_entries) as $m
  | {
      schema: iv_schema,
      readable: (($doc | type) == "object"),
      schemaVersion: $ver,
      legacy: $legacy,
      types: ($cfg.types // null),
      containers: ($cs | map({key: .name, value: {status: .status, reason: .reason}}) | from_entries),
      workers: $m.workers.members, asks: $m.asks.members, followUps: $m.followUps.members,
      lanes: $m.lanes.members, hosts: $m.hosts.members, deployWindows: $m.deployWindows.members,
      issues: ( [ $cs[] | select(.status == "invalid") | {sourcePath: .name, kind: "container", reason: .reason} ]
              + [ $cs[] | .members[] | . as $mem
                  | (if $mem.rowBad != false then [{sourcePath: $mem.sourcePath, kind: "rowBad", reason: $mem.rowBad}] else [] end)
                    + [ $mem.fields | to_entries[] | select(.value.status == "invalid") | {sourcePath: ($mem.sourcePath + "." + .key), kind: "field", reason: .value.reason} ] | .[] ]
              + (if $ver.status == "invalid" then [{sourcePath: "schemaVersion", kind: "field", reason: $ver.reason}] else [] end)
              + iv_scalar_issues($doc) )
    };

# iv_apply_dups($view; $dups): $dups is the list of paths (arrays) that scripts/jdupkeys found written twice in one object (jq itself keeps only the
# last of two equal keys, so a repeat is invisible to it). A member that holds a repeated path is rowBad (rule G): it counts, is named, holds what it
# might be and grants nothing. A container key written twice makes the container invalid. A repeated schemaVersion makes the version invalid.
def iv_apply_dups($view; $dups):
  def under($p): any($dups[]; (.[0:($p | length)]) == $p);
  def mark($c): .[$c] |= map(. as $m | ([$c, ($m.key // $m.index)]) as $p
      | if under($p) then .rowBad = ("a key is written twice in " + $m.sourcePath) else . end);
  def cmark($c): if any($dups[]; . == [$c]) then .containers[$c] = {status: "invalid", reason: ($c + " is written twice")} | .[$c] = [] else . end;
  ($dups | map(select(. == ["schemaVersion"])) | length > 0) as $vdup
  | $view
  | mark("workers") | mark("asks") | mark("followUps") | mark("lanes") | mark("hosts") | mark("deployWindows")
  | cmark("workers") | cmark("asks") | cmark("followUps") | cmark("lanes") | cmark("hosts") | cmark("deployWindows")
  | if $vdup then .schemaVersion = {value: null, status: "invalid", reason: "schemaVersion is written twice"} | .legacy = false else . end
  | .issues += ( [ .workers[], .asks[], .followUps[], .lanes[], .hosts[], .deployWindows[] | select(.rowBad != false and (.rowBad | startswith("a key is written twice")))
                   | {sourcePath: .sourcePath, kind: "rowBad", reason: .rowBad} ]
                 + [ $dups[] | select(length == 1 and (.[0] | IN("workers", "asks", "followUps", "lanes", "hosts", "deployWindows"))) | {sourcePath: .[0], kind: "container", reason: (.[0] + " is written twice")} ]
                 + [ "freeze", "health" | . as $k | select(any($dups[]; .[0] == $k)) | {sourcePath: $k, kind: "container", reason: ("a key is written twice in " + $k)} ] );

# ---- escalation of a follow-up (strict): a positive whole issue number OR a real GitHub issue/PR URL; text like "#12", "12" or "none" is not one
def iv_fu_escalated($m): ($m.fields.issue.status == "valid") or ($m.fields.issueUrl.status == "valid");

# ---- decisions ---------------------------------------------------------------------------------------------------------------------
# a worker action. ctx: {host: "<this host>", legacy?: bool (default: the view's)}
def iv_worker_member($view; $id): first($view.workers[] | select(.key == $id)) // null;

def iv_eff_host($m; $legacy):
  $m.fields.host as $h
  | if $h.status == "valid" then $h.value elif $h.status == "missing" and $legacy then $h.legacy else "unknown" end;
def iv_eff_state($m; $legacy):
  $m.fields.state as $s
  | if $s.status == "valid" then $s.value elif $s.status == "missing" and $legacy then $s.legacy else "unknown" end;
def iv_eff_standing($m; $legacy; $action):
  $m.fields.standing as $s
  | if $s.status == "valid" then $s.value elif $s.status == "missing" and $legacy then (if ($s.legacy | has($action)) then $s.legacy[$action] else "unknown" end) else "unknown" end;

def iv_live_states: ["running", "stuck", "blocked-on-owner"];

# bounded widening: can an unreadable member MIGHT-BE $target? true when no readable key rules it out.
# $lanes: the lane labels it is known to belong to (readable), compared to the target's readable lane.
# the lanes that exist: the keys of the lanes container and every readable lane a worker has. A lane named by a follow-up or an ask that is NONE of these
# (a near spelling: "L" for "l", "l ") is not a lane: it is unreadable, so what it belongs to is unknown and it holds
def iv_known_lanes($view): ([ ($view.lanes // [])[].key | strings ] + [ ($view.workers // [])[] | select(.rowBad == false and .fields.lane.status == "valid") | .fields.lane.value ]) | unique;
def iv_lane_unknown($laneField; $known): $laneField.status == "valid" and (($known | index($laneField.value)) == null);
def iv_lane_scope($tm; $laneField):
  ($tm.fields.lane) as $tl
  | if $laneField.status == "valid" and $tl.status == "valid" then ($laneField.value == $tl.value) else true end;

# iv_kids($ws): parent key -> the keys of the readable rows that name it as their (valid) parent. One pass, so the walks below cost one visit per row.
def iv_kids($ws):
  reduce $ws[] as $w ({}; if $w.rowBad == false and $w.fields.parent.status == "valid" then .[$w.fields.parent.value] += [$w.key] else . end);
# iv_reach($kids; $roots): $roots and everything below them in $kids, each row once. A row is visited the first time it is reached and never again, so a
# loop (a root that is below itself, or a self-parent) ends the walk instead of running for ever. One visit per row.
def iv_reach($kids; $roots):
  { seen: {}, frontier: ($roots | unique) }
  | until(.frontier | length == 0;
      reduce .frontier[] as $k ({seen: .seen, next: []}; if .seen[$k] then . else .seen[$k] = true | .next += ($kids[$k] // []) end)
      | {seen, frontier: (.next | unique)})
  | .seen | keys;

# iv_placed($workers): the keys of the workers whose parent chain reaches a root through readable rows (so a loop never enters it). Linear in the rows.
def iv_placed($ws):
  ($ws | map({key: .key, value: true}) | from_entries) as $has
  | iv_kids($ws) as $kids
  | iv_reach($kids; [ $ws[] | select(.rowBad == false and .fields.parent.status != "invalid"
                                     and (.fields.parent.status == "missing" or ($has[.fields.parent.value] | not))) | .key ]);

# open, unescalated follow-ups that hold the teardown of $id (bounded), as readable strings
def iv_followup_holds($view; $id):
  iv_worker_member($view; $id) as $tm
  | iv_kids($view.workers) as $kids
  | iv_reach($kids; [$id]) as $fam
  # a worker that cannot be PLACED may be a descendant of anything: it matters only when a follow-up names it. Placed = its chain of valid parents
  # reaches a root (no parent, or a parent that has no row: a dangling parent is the root of its own family) through readable rows only. A row that is
  # not readable, a parent that is unreadable, a parent whose row is not placed (so every descendant of an unplaceable row), and a chain that loops
  # are all unplaced.
  | iv_placed($view.workers) as $placed
  | ($placed | map({key: ., value: true}) | from_entries) as $isplaced
  | ($fam | map({key: ., value: true}) | from_entries) as $isfam
  | ([ $view.workers[] | select($isplaced[.key] | not) | .key ]) as $unplaceable
  | ($unplaceable | map({key: ., value: true}) | from_entries) as $isunp
  | ($view.workers | map({key: .key, value: true}) | from_entries) as $hasrow
  | iv_known_lanes($view) as $known
  # the rows whose lane a follow-up with NO readable worker may belong to: the target, everything below it, and every row that cannot be placed
  | ([ $view.workers[] | select($isfam[.key] or $isunp[.key]) ]) as $scope
  | [ $view.followUps[]
      | . as $f
      | select(.rowBad != false
               or ((.fields.state.status == "valid" and .fields.state.value == "done") | not))
      | select(.rowBad != false or (iv_fu_escalated($f) | not))
      | if .rowBad != false then "follow-up " + (.sourcePath) + " is unreadable (" + .rowBad + ")"
        elif .fields.worker.status != "valid"
          then (if iv_lane_unknown($f.fields.lane; $known) or any($scope[]; iv_lane_scope(.; $f.fields.lane)) then "follow-up " + (.fields.id.value // "?" | tostring) + " has no readable worker and may be this one's" else empty end)
        elif ($hasrow[.fields.worker.value] | not)
          then (if iv_lane_unknown($f.fields.lane; $known) or any($scope[]; iv_lane_scope(.; $f.fields.lane)) then "follow-up " + (.fields.id.value // "?" | tostring) + " names " + (.fields.worker.value | tojson) + ", which is no worker row (an exact name is needed), and may be this one's" else empty end)
        elif $isfam[.fields.worker.value] then "open follow-up " + (.fields.id.value // "?" | tostring) + " on " + .fields.worker.value
        elif $isunp[.fields.worker.value] then "open follow-up " + (.fields.id.value // "?" | tostring) + " on " + .fields.worker.value + ", a row that cannot be placed in a family"
        else empty end ];

# the target's own parent chain must reach a root through readable rows: a loop (itself included), a row that cannot be read or a parent that cannot be placed means the family
# it belongs to cannot be told, so the teardown is held
def iv_chain_holds($view; $id):
  (iv_placed($view.workers) | index($id)) as $at
  | if $at == null then ["the parent chain of " + ($id | tostring) + " cannot be placed (a loop, or a row on the way up cannot be read)"] else [] end;

def iv_lane_holds($view; $id):
  iv_worker_member($view; $id) as $tm
  | ($view.workers | map({key: .key, value: true}) | from_entries) as $hasrow
  | [ $view.lanes[] | . as $l
      | if $l.rowBad != false then "lane " + ($l.key // "?") + " is unreadable"
        else
          ( if $l.fields.lead.status == "valid" then (if $l.fields.lead.value == $id then "is the lead of lane " + $l.key
                                                       elif ($hasrow[$l.fields.lead.value] | not) then (if ($tm.fields.lane.status == "valid" and $tm.fields.lane.value != $l.key) then empty else "lane " + $l.key + " lead " + ($l.fields.lead.value | tojson) + " is no worker row (an exact name is needed)" end)
                                                       else empty end)
            elif $l.fields.lead.status == "invalid" then (if ($tm.fields.lane.status == "valid" and $tm.fields.lane.value != $l.key) then empty else "lane " + $l.key + " lead is unreadable" end)
            else empty end ),
          # a lane state outside the enum (a number, false, blank, an unknown spelling) holds the workers that may belong to the lane
          ( if $l.fields.state.status == "invalid" then (if ($tm.fields.lane.status == "valid" and $tm.fields.lane.value != $l.key) then empty else "lane " + $l.key + " state is unreadable (" + $l.fields.state.reason + ")" end) else empty end )
        end ];

# an ask HOLDS the teardown of a worker while it is open (state open, in-progress, missing or unreadable: only answered, decided and closed let go) and
# is about that worker. WHO an ask is about, strongest first: a readable `worker` names it (equal holds, different does not); else its lane, pr and
# path are compared with the worker's. A tie field that is unreadable, or a readable one the worker has no readable counterpart for, MAY be the tie:
# held. An ask that names nothing readable at all (no worker, lane, pr or path) may be about anyone: held. An ask row that is not an object, or in which a
# key is written twice (the surviving value cannot be trusted), holds every teardown. The ask's id does not matter: a null, blank or duplicate id still holds.
def iv_ask_open($a): ($a.fields.state.status != "valid") or ($a.fields.state.value | IN("open", "in-progress"));
def iv_ask_ties($a; $tm; $id; $known):
  def cmp($af; $wf; norm):
    if $af.status == "missing" then empty
    elif $af.status == "invalid" then null
    elif $wf.status == "valid" then (($af.value | norm) == ($wf.value | norm))
    else null end;
  if $a.fields.worker.status == "valid" then [ ($a.fields.worker.value == $id) ]
  else
    ( [ (if $a.fields.worker.status == "invalid" then null else empty end),
        (if iv_lane_unknown($a.fields.lane; $known) then null else cmp($a.fields.lane; $tm.fields.lane; .) end),
        cmp($a.fields.pr; $tm.fields.pr; .),
        cmp($a.fields.path; $tm.fields.path; iv_normp) ] ) as $t
    | if ($t | length) == 0 then [null] else $t end
  end;
def iv_row_dup: type == "string" and startswith("a key is written twice");
def iv_ask_holds($view; $id):
  iv_worker_member($view; $id) as $tm
  | iv_known_lanes($view) as $known
  | [ $view.asks[] | . as $a
      | if ($a.fields | length) == 0 or ($a.rowBad | iv_row_dup) then "ask " + $a.sourcePath + " is unreadable (" + $a.rowBad + ")"
        elif (iv_ask_open($a) | not) then empty
        else
          iv_ask_ties($a; $tm; $id; $known) as $ties
          | ($a.fields.id.value // $a.sourcePath) as $n
          | if any($ties[]; . == true) then "open ask " + ($n | tostring) + " is about this worker"
            elif any($ties[]; . == null) then "open ask " + ($n | tostring) + " may be about this worker (what it is tied to is unreadable or not named)"
            else empty end
        end ];

def iv_decide($action; $view; $id; $ctx):
  ($ctx.legacy // $view.legacy) as $legacy
  | iv_worker_member($view; $id) as $m
  | ($ctx.host // "local") as $here
  | if $view.readable | not then {action: $action, target: $id, permit: false, reasons: ["the ledger is unreadable"], snapshot: null}
    elif $view.containers.workers.status != "valid" then {action: $action, target: $id, permit: false, reasons: ["workers is " + ($view.containers.workers.status) + ": " + ($view.containers.workers.reason // "absent")], snapshot: null}
    elif $m == null then {action: $action, target: $id, permit: false, reasons: ["no such worker row"], snapshot: null}
    elif $m.rowBad != false then {action: $action, target: $id, permit: false, reasons: ["the worker row is unreadable: " + $m.rowBad], snapshot: null}
    else
      iv_eff_host($m; $legacy) as $host
      | iv_eff_state($m; $legacy) as $state
      | iv_eff_standing($m; $legacy; $action) as $standing
      | $m.fields.path as $path
      | ( [ (if ($here | iv_nonblank | not) then "the host this decision is for is blank" else empty end),
            (if $view.schemaVersion.status == "invalid" then "schemaVersion is invalid" else empty end),
            (if $host == "unknown" then "host is unreadable (" + ($m.fields.host.reason // "absent") + ")" elif $host != $here then "worker is on host " + $host + ", this decision is for " + $here else empty end),
            (if $path.status != "valid" then "path is unreadable (" + ($path.reason // "absent") + ")" else empty end),
            (if $state == "unknown" then "state is unknown (" + ($m.fields.state.reason // "absent") + ")" else empty end),
            (if $standing == "unknown" then "standing is unknown (" + ($m.fields.standing.reason // "absent") + ")" else empty end) ]
          + (if $action == "sleep" then
               [ (if $standing == false then "not a standing lead" else empty end),
                 (if $state != "unknown" and (iv_live_states | index($state)) == null then "state " + $state + " is not a running one" else empty end) ]
             elif $action == "nudge" then
               [ (if $state != "unknown" and (iv_live_states | index($state)) == null then "state " + $state + " is not nudgeable" else empty end) ]
             elif $action == "resume" then
               [ (if $standing == false then "resume is for a standing lead" else empty end),
                 (if $state != "unknown" and (iv_live_states | index($state)) == null then "state " + $state + " is not resumable" else empty end) ]
             elif $action == "capacity_kill" then
               [ (if $standing == true then "a standing lead is never a capacity candidate" else empty end),
                 (if $state != "unknown" and (iv_live_states + ["done", "retired"] | index($state)) == null then "state " + $state + " is not a candidate" else empty end) ]
             elif $action == "teardown" then
               [ (if $standing == true then "standing: never torn down" else empty end),
                 (if $state == "asleep" then "state " + $state + " is kept" else empty end),
                 (if $m.fields.parent.status == "invalid" then "parent is unreadable (" + $m.fields.parent.reason + ")" else empty end),
                 (if $m.fields.beadsEpic.status == "invalid" then "beadsEpic is unreadable" else empty end),
                 (if $m.fields.epicConflict.status == "invalid" then "epicConflict is unreadable" elif ($m.fields.epicConflict.status == "valid" and ($m.fields.epicConflict.value | length) > 0) then "epic conflict recorded" else empty end),
                 (if $view.containers.followUps.status == "invalid" then "followUps is unreadable" elif $view.containers.followUps.status == "missing" and ($legacy | not) then "followUps is missing (schemaVersion 2 requires it)" else empty end),
                 (if $view.containers.lanes.status == "invalid" then "lanes is unreadable" elif $view.containers.lanes.status == "missing" and ($legacy | not) then "lanes is missing (schemaVersion 2 requires it)" else empty end),
                 (if $view.containers.asks.status == "invalid" then "asks is unreadable (" + $view.containers.asks.reason + ")" elif $view.containers.asks.status == "missing" and ($legacy | not) then "asks is missing (schemaVersion 2 requires it)" else empty end) ]
               + iv_chain_holds($view; $id) + iv_followup_holds($view; $id) + iv_lane_holds($view; $id) + iv_ask_holds($view; $id)
             else ["unknown action " + $action] end ) ) as $reasons
      | { action: $action, target: $id, permit: (($reasons | length) == 0), reasons: $reasons,
          snapshot: { host: $host, path: ($path.value // null), state: $state, standing: $standing, parent: ($m.fields.parent.value // null), lane: ($m.fields.lane.value // null) } }
    end;

# ---- the live-reply adapter: Orca / plugly / ssh answers read at the moment of action ----------------------------------------------------
# A reply is never trusted by shape, and ALWAYS yields one envelope (never zero outputs). complete is true only when the reply is an object whose
# result is an object, ok is not false, the list is an array, truncated is absent or exactly false, and totalCount is absent or a whole number
# that fits in the rows read. Any other shape is complete:false with the reason.
# $dups: the paths scripts/jdupkeys found written twice in the reply (jq keeps the last of two equal keys, so `"truncated":true,"truncated":false` would
# read as complete); any repeat makes the reply incomplete.
def iv_live_list($reply; $path; $name; $dups):
  def bad($why): {name: $name, complete: false, reason: $why, rows: []};
  try (
    if ($dups | length) > 0 then bad("a key is written twice in the reply (" + ($dups[0] | map(tostring) | join(".")) + ")")
    elif ($reply | type) != "object" then bad("the reply is not an object")
    elif ($reply | has("ok")) and $reply.ok != true then bad("ok is not true")
    elif ($reply.result | type) != "object" then bad("result is not an object")
    elif ($reply.result[$name] | type) != "array" then bad($name + " is not a list")
    elif ($reply.result | has("truncated")) and $reply.result.truncated != false then bad("truncated is not false")
    elif ($reply.result | has("totalCount")) and $reply.result.totalCount != null
         and (($reply.result.totalCount | type) != "number" or $reply.result.totalCount < 0 or $reply.result.totalCount != ($reply.result.totalCount | floor)) then bad("totalCount is not a whole number")
    elif ($reply.result | has("totalCount")) and $reply.result.totalCount != null and $reply.result.totalCount > ($reply.result[$name] | length) then bad("total count is more than the rows read")
    else {name: $name, complete: true, reason: null, rows: $reply.result[$name]} end
  ) catch bad("the reply could not be read");

# terminals: agent = "agent" (a named agent runs), "shell" (the key is absent or null: a plain shell), "unknown" (not readable: never read as a shell)
def iv_live_terminals($reply; $cfg; $dups):
  iv_live_list($reply; ["result", "terminals"]; "terminals"; $dups) as $l
  | $l + { terminals: [ $l.rows | to_entries[]
        | iv_member("terminals[" + (.key | tostring) + "]"; null; .key; .value;
            ( . as $r | { handle: iv_get($r; "handle"; "str"; $cfg), worktreeId: iv_get($r; "worktreeId"; "str"; $cfg), worktreePath: iv_get($r; "worktreePath"; "path"; $cfg),
                          agentIdentity: iv_get($r; "agentIdentity"; "str"; $cfg) } ))
        | . + { agent: (if .rowBad != false then "unknown" elif .fields.agentIdentity.status == "valid" then "agent" elif .fields.agentIdentity.status == "missing" then "shell" else "unknown" end) } ] }
  | del(.rows);
def iv_live_terminals($reply; $cfg): iv_live_terminals($reply; $cfg; []);

def iv_live_worktrees($reply; $cfg; $dups):
  iv_live_list($reply; ["result", "worktrees"]; "worktrees"; $dups) as $l
  | $l + { worktrees: [ $l.rows | to_entries[]
        | iv_member("worktrees[" + (.key | tostring) + "]"; null; .key; .value;
            ( . as $r | { id: iv_get($r; "id"; "str"; $cfg), path: iv_get($r; "path"; "path"; $cfg), comment: iv_get($r; "comment"; "text"; $cfg) } )) ] }
  | del(.rows);
def iv_live_worktrees($reply; $cfg): iv_live_worktrees($reply; $cfg; []);

# a screen or tail read: text or nothing. A non-text reply is unknown, never an empty screen.
def iv_live_text($v): if ($v | type) == "string" then {status: "valid", value: $v, reason: null} elif $v == null then {status: "missing", value: null, reason: null} else {status: "invalid", value: null, reason: ("screen is " + ($v | type) + ", not text")} end;

# ---- the migration manifest (dry run, READ ONLY): what a stamp to schemaVersion 2 would have to settle first --------------------------------------
# iv_manifest($doc; $view): per worker the keys missing (path, state, standing, host), a path alias to move to `path`, a legacy state spelling, invalid fields
# and a row that cannot be read; the follow-ups whose `issue` is text like "#12" or "12" (to be written as a number); terminal-only rows (a terminal and no
# path); and EVERY member of followUps, asks, lanes, hosts and deployWindows that is unreadable, has an invalid field or lacks a required one
# (asks: id, state; followUps: id, worker, lane, owner, state; deployWindows: id, state); and every REQUIRED container that is absent or null
# (workers, asks, followUps, lanes: iv_required_containers); a present freeze (state, ttl, window) or health of the wrong shape, or a repeated key under either;
# a worker whose parent chain cannot be placed (itself, a loop, an unreadable row on the way up); and follow-up ids used twice. A dangling parent is reported
# (danglingParents) and does not make the manifest unclean. `clean` is true only when nothing is listed: a later stamp verb
# sets schemaVersion 2 only then. Writes nothing.
# the OPERATIONAL fields of a worker row: the ones the closed type table in lib.sh (cm_row_types, cm_live_types, cm_health_types) names, which the scripts read to decide
# (agent, live.*, health.*, counters, times). The same test as lib.sh cm_row_fields_ok: a present value (null is absent) of the wrong type, a string field holding a control
# character, a live or health that is not an object. $t is the table from the view ($view.types); an absent table checks nothing here.
def iv_type_is($t): if $t == "count" then (type == "number" and . >= 0 and . == floor) elif $t == "time" then (type == "string" or type == "number") elif $t == "text" then type == "string" else type == $t end;
def iv_oper_problems($row; $types):
  if ($types | type) != "object" or ($row | type) != "object" then []
  else
    def bad($o; $tbl; $pre):
      [ $tbl | to_entries[] | . as $e | ($o[$e.key]) as $v | select($v != null)
        | if ($v | iv_type_is($e.value) | not) then {field: ($pre + $e.key), reason: ($pre + $e.key + " is not " + $e.value + " (a " + ($v | type) + ")")}
          elif ($e.value == "string" and ($v | type) == "string" and ($v | test("\\p{Cc}|\\p{Zl}|\\p{Zp}"))) then {field: ($pre + $e.key), reason: ($pre + $e.key + " holds a control character")}
          else empty end ];
    bad($row; $types.row; "")
    + (if $row.live == null then [] elif ($row.live | type) != "object" then [{field: "live", reason: "live is not an object"}] else bad($row.live; $types.live; "live.") end)
    + (if $row.health == null then [] elif ($row.health | type) != "object" then [{field: "health", reason: "health is not an object"}] else bad($row.health; $types.health; "health.") end)
  end;

def iv_required_containers: ["workers", "asks", "followUps", "lanes"];
def iv_required: {asks: ["id", "state"], followUps: ["id", "worker", "lane", "owner", "state"], deployWindows: ["id", "state"], lanes: [], hosts: []};
def iv_manifest($doc; $view):
  ([ $view.workers[]
     | . as $m
     | { worker: .key,
         rowBad: (if .rowBad != false then .rowBad else null end),
         missing: [ "path", "state", "standing", "host" | select($m.fields[.]? != null and $m.fields[.].status == "missing") ],
         aliasToMove: (if $m.fields.path.status == "valid" and ($m.fields.path.source // "path") != "path" then {from: $m.fields.path.source, to: "path", value: $m.fields.path.value} else null end),
         stateSpelling: (if $m.fields.state.status == "valid" and $m.fields.state.spelling != $m.fields.state.value then {from: $m.fields.state.spelling, to: $m.fields.state.value} else null end),
         invalid: ([ $m.fields | to_entries[]? | select(.value.status == "invalid") | {field: .key, reason: .value.reason} ]
                   + (if $m.rowBad == false then iv_oper_problems($doc.workers[$m.key]?; $view.types) | map(select(.field as $f | $m.fields[$f]? == null or $m.fields[$f].status != "invalid")) else [] end)),
         terminalOnly: ($m.rowBad == false and $m.fields.terminal.status == "valid" and $m.fields.path.status == "missing") }
     | select(.rowBad != null or (.missing | length) > 0 or .aliasToMove != null or .stateSpelling != null or (.invalid | length) > 0 or .terminalOnly) ]) as $w
  | ([ $view.followUps[]
       | . as $m | ($doc.followUps[$m.index]?) as $raw
       | select($m.rowBad == false and ($raw.issue? | type) == "string" and ($raw.issue | test("\\A#?[0-9]+\\z")))
       | {followUp: ($m.fields.id.value // ("followUps[" + ($m.index | tostring) + "]")), issue: $raw.issue, asNumber: ($raw.issue | ltrimstr("#") | tonumber)} ]) as $f
  | [ [ ["asks", $view.asks], ["followUps", $view.followUps], ["lanes", $view.lanes], ["hosts", $view.hosts], ["deployWindows", $view.deployWindows] ][]
      | . as [$c, $ms] | $ms[]
      | . as $m
      | { container: $c, member: $m.sourcePath,
          rowBad: (if $m.rowBad != false then $m.rowBad else null end),
          missing: (if $m.rowBad == false then [ iv_required[$c][] | select($m.fields[.].status == "missing") ] else [] end),
          invalid: [ $m.fields | to_entries[]? | select(.value.status == "invalid") | {field: .key, reason: .value.reason} ] }
      | select(.rowBad != null or (.missing | length) > 0 or (.invalid | length) > 0) ] as $mem
  | ([ $mem[] | select(.container == "asks" and .rowBad != null) | {ask: .member, reason: .rowBad} ]) as $a
  | ($view.issues | map(select(.kind == "container"))) as $c
  | ([ iv_required_containers[] | select($view.containers[.].status == "missing") ]) as $mc
  # workers whose parent chain cannot be placed (a loop, itself, a row that cannot be read on the way up): the teardown decision holds their follow-ups, so a
  # stamp to schemaVersion 2 must settle them first. A parent with no row at all is NOT one of these: it is the root of its own family, and is only reported.
  | ($view.workers | map({key: .key, value: .}) | from_entries) as $byk
  | (iv_placed($view.workers) | map({key: ., value: true}) | from_entries) as $isp
  | ([ $view.workers[] | select(.rowBad == false and .fields.parent.status == "valid" and ($isp[.key] | not))
       | . as $w
       | { worker: .key, parent: .fields.parent.value,
           why: (if .fields.parent.value == .key then "is its own parent"
                 else ( { cur: .fields.parent.value, seen: [.key] }
                        | until(.cur == null or (.cur as $c | (.seen | index($c)) != null) or ($byk[.cur] == null) or ($byk[.cur].rowBad != false) or ($byk[.cur].fields.parent.status != "valid");
                                { cur: $byk[.cur].fields.parent.value, seen: (.seen + [.cur]) })
                        | if (.cur as $c | (.seen | index($c)) != null) then "its parent chain loops" else "its parent chain runs through a row that cannot be read" end ) end) } ]) as $pp
  | ([ $view.workers[] | select(.rowBad == false and .fields.parent.status == "valid" and ($byk[.fields.parent.value] == null)) | {worker: .key, parent: .fields.parent.value} ]) as $dp
  | ([ $view.followUps[] | select(.rowBad == false and .fields.id.status == "valid") | .fields.id.value ] | group_by(.) | map(select(length > 1) | {id: .[0], count: length})) as $di
  | { schema: "cm.migration/v1", dryRun: true,
      schemaVersion: ($view.schemaVersion.value // null), schemaVersionStatus: $view.schemaVersion.status,
      readable: $view.readable,
      workers: $w, followUpIssues: $f, asksWithoutId: $a, members: $mem, containerIssues: $c, missingContainers: $mc,
      parentProblems: $pp, danglingParents: $dp, duplicateFollowUpIds: $di,
      counts: { workers: ($view.workers | length), workersToSettle: ($w | length), followUpIssuesToFix: ($f | length), asksToFix: ($a | length), membersToSettle: ($mem | length), containerIssues: ($c | length), missingContainers: ($mc | length), parentProblems: ($pp | length), danglingParents: ($dp | length), duplicateFollowUpIds: ($di | length) },
      clean: ($view.readable and $view.schemaVersion.status != "invalid" and ($w | length) == 0 and ($f | length) == 0 and ($mem | length) == 0 and ($c | length) == 0 and ($mc | length) == 0 and ($pp | length) == 0 and ($di | length) == 0) };
