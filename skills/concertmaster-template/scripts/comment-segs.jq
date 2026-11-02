# comment-segs.jq: the one way a worktree comment is cut into segments. A jq module: `include "comment-segs";`
# with `jq -L <scripts dir>`. asks.sh and fleet-state.sh read comments through it.
#
# comment_segs: any value -> array of trimmed, non-empty strings. Only a string is read (a number, object,
# array or null is an empty comment, never a crash). A literal backslash-n counts as a newline, then every
# line is also split on " | ", so a tag after a pipe on line 1 is a segment of its own.
def comment_segs:
  (if type == "string" then . else "" end) | gsub("\\\\n"; "\n")
  | [ split("\n")[] | split(" | ")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0) ];
