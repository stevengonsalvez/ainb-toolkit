# lesson-parse.jq: the one parser for a lesson line. A jq module: `include "lesson-parse";` with `jq -L <scripts dir>`.
# Line format (references/lanes.md Lead charter 5b):  cm:lesson <lane> | <what happened and the fix> | root cause: <gap>
#
# lessons_in: any value -> array of {lane, text, root}. Only a string is read. A literal backslash-n is a newline.
# The pipes belong to the format here, so a line is cut on " | " and a lesson is read from the segment
# `cm:lesson <lane>` up to the next `root cause:` segment (taken as root) or the next `cm:` segment (root empty);
# a lesson may therefore follow other segments on line 1 (`cm:running | cm:lesson lane-a | ... | root cause: ...`).
# A lesson with neither text nor root is dropped.
def lessons_in:
  (if type == "string" then . else "" end) | gsub("\\\\n"; "\n") | split("\n")
  | map(split(" | ") | map(sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(length > 0)))
  | map(
      . as $s
      | [ range(0; $s | length) | select($s[.] | test("^cm:lesson\\s+[^\\s|]+$")) ][] as $i
      | ($s[$i] | capture("^cm:lesson\\s+(?<lane>[^\\s|]+)$").lane) as $lane
      | ( [ range($i + 1; $s | length) | select($s[.] | test("^(root cause:|cm:)"; "i")) ] | first // null ) as $stop
      | { lane: $lane,
          text: ($s[($i + 1):(if $stop == null then ($s | length) else $stop end)] | join(" | ")),
          root: (if $stop != null and ($s[$stop] | test("^root cause:"; "i")) then ($s[$stop] | sub("^root cause:\\s*"; ""; "i")) else "" end) }
    )
  | flatten
  | map(select(.text != "" or .root != ""));
