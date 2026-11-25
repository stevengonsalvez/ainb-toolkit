#!/usr/bin/env bash
# ask-timeout-base.sh (test library, sourced by ask-timeout-fuzz.sh and field-reads.sh; not a test). The MAXIMAL base ledger of
# ask-timeout.sh: every ledger field its classifier reads (scripts/test/fixtures/asktimeout-fields.tsv lists them) is present, and
# the two asks are built so that a wrong-typed value in each field would LOWER a protection if it were read as absent or coerced:
#   at-a   kind and scope both "code", a pr, files listed, noCode false, its own lane      (files path)
#   at-b   scope and pr null, files null, noCode true, no lane of its own (the worker w-dev decides it)   (noCode path)
# Both are verdict-due at CM_NOW 2026-10-17T19:00:00Z. mkatbase <file> writes the ledger. Synthetic names only.
mkatbase() { # mkatbase <file>
  jq -n '
    {kind: "code", issue: 1, state: "open", verdictRef: null, verdictStartedAt: null,
     askedAt: "2026-10-17T17:00:00Z", timeoutAt: "2026-10-17T17:30:00Z",
     question: "split the card?", topic: "card", worker: "w-dev"} as $b
    | {schema: "concertmaster.ledger/v1", project: "acme",
       workers: {"w-dev": {lane: "dev-sweeper", pr: null}},
       asks: [
         ($b + {id: "at-a", scope: "code", lane: "dev-sweeper", path: "/w/acme/at-a", files: ["src/a.ts"], noCode: false, pr: 7}),
         ($b + {id: "at-b", scope: null, lane: null, path: "/w/acme/at-b", files: null, noCode: true, pr: null})]}' > "$1"
}
