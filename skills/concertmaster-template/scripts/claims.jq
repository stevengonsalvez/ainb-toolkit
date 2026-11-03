# claims.jq: the one way a lead's worktree comment is read for the worker names it claims. A jq module:
# `include "claims";` with `jq -L <scripts dir>`. classify.jq (ownership accounting) and teardown.sh (the
# lead-mode rival-claim scan) read comments through it, so a name one treats as claimed is claimed by the other.
#
def lc: ascii_downcase;
def rxesc: gsub("(?<c>[\\\\.^$|?*+()\\[\\]{}])"; "\\" + .c);
def tokens: [ match("[A-Za-z0-9][A-Za-z0-9._-]*"; "g").string | sub("[._-]+$"; "") | lc ];
# Worker names a lead lists in $text: after each marker that starts the comment, a
# " | " section, a sentence ("... . OWNED (x): a, b") or a "cm:<state> " prefix (or follows
# ", ", ": " or " - " directly before ( [ or :), and is written as a
# header (followed by "(", "[" or ":" or by a few words and a colon), up to the
# next " | ", the next "<stop word>:", the next ALL-CAPS header, or the end.
# Parenthesised text is masked for the marker, pipe, stop-word and name search
# (a "(cm: nudged)" never cuts a list, a "(not owned)" never starts one, a name
# inside a parenthesis is never claimed); a marker after "not", "not-", "never",
# "no longer" or "dis" is a negation. Only names in $names count, so prose and
# host names never become owners.
def mask: gsub("(?<p>\\([^()]*\\))"; (.p | length) as $n | " " * $n);
def claims($text; $mk; $stop; $names):
  ($text | mask | mask) as $m
  # "cm:child <name> (...)": one worker per line, the name is the first token after the tag and the rest
  # of the line is a description (a PR number or "merged" there never names a worker). Same token shape
  # as teardown.sh and followups.sh (up to a space, comma or "@host"; a literal "\n" is a newline), but
  # census-tolerant where they are strict: case is ignored, a leading bracket, quote or backtick and anything from
  # a parenthesis on are dropped (so "cm:child x-fix(PR 1)" claims x-fix), trailing punctuation is dropped, and a name
  # is matched without its host, like every other marker list. It starts the comment, a line or a " | "
  # section, after an optional "cm:<state> ", so "no longer cm:child x" and "(cm:child x)" claim nothing.
  # Read only when "cm:child" is a configured marker. Other markers go through the header-list parser
  # below, so "cm:child" is taken out of that regex.
  | (if ($mk | map(ascii_downcase) | index("cm:child")) != null then
       ($text | gsub("\\\\n"; "\n")) as $tn
       | ($tn | mask | mask) as $mn
       # a match whose text is blanked in the masked copy sits inside a parenthesis: ignored
       | [ $tn
         | match("(?:\\A|\\| |\\n)[ \\t]*(?:cm:[A-Za-z-]+[ \\t]+)?cm:child[ \\t]+[\\[`'\"]?([^\\s,@()\\[\\]/`'\"]+)"; "gi")
         | select($mn[.offset:(.offset + .length)] == .string)
         | .captures[0].string
         | sub("[.:;_-]+$"; "") | ascii_downcase | select(. as $t | $names | index($t)) ]
     else [] end) as $kids
  | ($mk | map(select(ascii_downcase != "cm:child"))) as $mk
  | ($mk | map(rxesc) | join("|")) as $mre
  | (if ($stop | length) > 0 then "\\b(" + ($stop | map(rxesc) | join("|")) + ")\\s*:" else null end) as $sre
  # strong boundaries (comment start, pipe section, sentence, line, a "cm:<state> " prefix) allow the
  # "few words and a colon" header; weak ones (", " ": " " - ") need the marker right before ( [ or :
  | ("(?:\\A|\\| |[.;] |\\n|cm:[A-Za-z-]+\\s+)\\s*\\b(" + $mre + ")") as $strong
  | ("(?:, |: | - )\\b(" + $mre + ")(?=\\s*[(\\[:])") as $weak
  | (if ($mk | length) == 0 then [] else
     [ ($strong, $weak) as $rx | $m | match($rx; "gi") | .captures[0] as $mk0
      | select(($text[($mk0.offset + $mk0.length):]) | test("^(\\s*[(\\[:]|(?![^:|()\\n]{0,40}\\bby\\b)[^:|()\\n]{0,40}:)"))
      | select(($text[($mk0.offset + $mk0.length):]) | test("^\\s*\\([^)]*\\b(not|never|no longer)\\b") | not)
      | {offset: $mk0.offset, length: $mk0.length}
      | ($m[(.offset + .length):]) as $mrest
      | ([ ([$mrest | match(" \\| ")] | first | .offset?),
           (if $sre == null then null else ([$mrest | match($sre; "i")] | first | .offset?) end),
           ([$mrest | match("\\b[A-Z]{2,}[A-Z0-9 ]*:")] | first | .offset?),
           ([$mrest | match("\\.\\s")] | first | .offset?) ]
         | map(select(. != null)) | if length == 0 then ($mrest | length) else min end) as $e
      | $mrest[:$e] | tokens[] | select(. as $t | $names | index($t)) ] end) + $kids | unique;
