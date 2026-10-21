#!/usr/bin/env bash
# fleet-install: bring a host to the toolkit's skills, MCP servers and plugins.
#   skills + MCP : apm install -g, from apm/apm.yml
#   plugins      : native `claude plugin install` from external-dependencies.yaml (default),
#                  or apm via apm/plugins.apm.yml (--plugins apm). One path per host, not both.
# Usage: scripts/fleet-install.sh [--plugins native|apm|none] [--dry-run]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGINS=native DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plugins) PLUGINS="${2:?native|apm|none}"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
for c in apm yq jq; do command -v "$c" >/dev/null || { echo "fleet-install: $c is required" >&2; exit 1; }; done
run() { if [ "$DRY" = 1 ]; then echo "+ $*"; else "$@"; fi; }

# apm reads one manifest, ~/.apm/apm.yml; keep a backup when replacing a different one.
install_apm_manifest() {
  local src="$1" dst="$HOME/.apm/apm.yml"
  [ "$DRY" = 1 ] && { echo "+ install $src as $dst, then apm install -g"; return; }
  mkdir -p "$HOME/.apm"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then cp -p "$dst" "$dst.bak-$(date +%Y%m%d%H%M)"; fi
  cp "$src" "$dst" && apm install -g
}

case "$PLUGINS" in
  apm)
    merged="$(mktemp)"
    yq eval-all 'select(fi==0) *+ select(fi==1) | .targets |= unique' "$ROOT/apm/apm.yml" "$ROOT/apm/plugins.apm.yml" > "$merged"
    install_apm_manifest "$merged"; rm -f "$merged" ;;
  native|none)
    install_apm_manifest "$ROOT/apm/apm.yml"
    if [ "$PLUGINS" = native ]; then
      command -v claude >/dev/null || { echo "fleet-install: claude is required for native plugins" >&2; exit 1; }
      fail=0
      while IFS=$'\t' read -r name mkt id; do
        [ -n "$mkt" ] || continue
        if [ "$DRY" = 1 ]; then echo "+ claude plugin marketplace add $mkt"
        else claude plugin marketplace add "$mkt" >/dev/null 2>&1 || true; fi   # already added is fine
        run claude plugin install "$name@$id" || { echo "fleet-install: $name@$id failed" >&2; fail=$((fail+1)); }
      done < <(yq -o=json '."claude-plugins"' "$ROOT/external-dependencies.yaml" | jq -r '.[]|select(.marketplace_id!=null)|[.name,.marketplace,.marketplace_id]|@tsv')
      [ "$fail" = 0 ] || echo "fleet-install: $fail plugin install(s) failed" >&2
    fi ;;
  *) echo "unknown --plugins value: $PLUGINS" >&2; exit 2 ;;
esac
