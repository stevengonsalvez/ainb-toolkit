#!/usr/bin/env bash
# Forget an inbox locally. Usage: expire.sh <slug>
# Neither provider deletes remotely: agents-inbox drops open-tier inboxes after
# 24h idle, and the InboxAPI mailbox is shared and persistent.
source "$(dirname "$0")/_lib.sh"
STATE=$(state_file "${1:-}")
rm -f "$STATE"   # idempotent: teardown under set -e must not fail
echo "forgot $1"
