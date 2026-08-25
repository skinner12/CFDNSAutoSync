#!/usr/bin/env bash
#
# Verifies that --dry-run suppresses notifications and does not consume the
# notification cooldown.
#
# Background: the dry-run guard only ever wrapped the DNS write inside
# update_cloudflare_dns, so send_notification ran unconditionally. A dry-run
# against a live config fired nine real Telegram alerts. Worse, each one wrote a
# cooldown timestamp, which would have silently suppressed a genuine failover
# alert for the next 30 minutes. A dry-run must observe, never emit.
#
# Usage: bash tests/dry_run_notifications_test.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET="$SCRIPT_DIR/cloudflare_dns_updater.sh"

TESTS_RUN=0
TESTS_FAILED=0

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  ok      %s\n' "$1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL    %s\n            %s\n' "$1" "$2"
}

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# shellcheck source=/dev/null
source "$TARGET"

# shellcheck disable=SC2034
LOG_FILE="$WORKDIR/test.log"
NOTIFICATION_CACHE_DIR="$WORKDIR/notification_cache"

SENT_LOG="$WORKDIR/sent.log"

NOTIF_CONFIG='{
  "enabled": true,
  "events": ["failover", "failback", "both_offline"],
  "cooldown_minutes": 30,
  "channels": {
    "telegram": {"enabled": true, "bot_token": "stub-token", "chat_id": "-100"},
    "slack": {"enabled": true, "webhook_url": "https://hooks.invalid/x"},
    "webhook": {"enabled": true, "url": "https://endpoint.invalid/notify"}
  }
}'

# Record every channel dispatch instead of hitting the network. If any of these
# runs during a dry-run, the guard under test is missing.
send_telegram() { printf 'telegram %s %s\n' "$2" "$3" >> "$SENT_LOG"; }
send_slack()    { printf 'slack %s %s\n'    "$2" "$3" >> "$SENT_LOG"; }
send_webhook()  { printf 'webhook %s %s\n'  "$2" "$3" >> "$SENT_LOG"; }

reset_state() {
    : > "$SENT_LOG"
    rm -rf "$NOTIFICATION_CACHE_DIR"
}

# ─── 1. A dry-run emits nothing ──────────────────────────────────────────────

printf 'Dry-run suppresses notifications\n'

reset_state
DRY_RUN=true
send_notification "$NOTIF_CONFIG" "true" "both_offline" "example.test" \
    "203.0.113.10" "198.51.100.20" "stubbed reason" >/dev/null 2>&1

if [[ -s "$SENT_LOG" ]]; then
    fail "no channel is dispatched during a dry-run" \
         "dispatched: $(tr '\n' ' ' < "$SENT_LOG")"
else
    pass "no channel is dispatched during a dry-run"
fi

# ─── 2. A dry-run does not consume the cooldown ──────────────────────────────
#
# should_send_notification stamps a timestamp file whenever it allows a send.
# If a dry-run stamps it, the next real alert for the same domain and event is
# suppressed for the whole cooldown window.

if [[ -e "$NOTIFICATION_CACHE_DIR/example.test_both_offline" ]]; then
    fail "a dry-run does not write a cooldown timestamp" \
         "cooldown file was created, so a later real alert would be suppressed"
else
    pass "a dry-run does not write a cooldown timestamp"
fi

# A real alert immediately afterwards must still go out. Clear the dispatch log
# but keep any cooldown state, otherwise a stale entry from the dry-run above
# would satisfy the assertion without a new send happening.
: > "$SENT_LOG"
DRY_RUN=false
send_notification "$NOTIF_CONFIG" "true" "both_offline" "example.test" \
    "203.0.113.10" "198.51.100.20" "stubbed reason" >/dev/null 2>&1

if grep -q '^telegram ' "$SENT_LOG"; then
    pass "a real alert after a dry-run is still delivered"
else
    fail "a real alert after a dry-run is still delivered" \
         "nothing dispatched: the dry-run consumed the cooldown"
fi

# ─── 3. Normal operation is unchanged ────────────────────────────────────────

printf '\nNormal operation is unaffected\n'

reset_state
DRY_RUN=false
send_notification "$NOTIF_CONFIG" "true" "failover" "example.test" \
    "203.0.113.10" "198.51.100.20" "stubbed reason" >/dev/null 2>&1

for channel in telegram slack webhook; do
    if grep -q "^${channel} " "$SENT_LOG"; then
        pass "$channel is dispatched when not in dry-run"
    else
        fail "$channel is dispatched when not in dry-run" \
             "no $channel dispatch recorded"
    fi
done

# The per-domain opt-out and the global switch must still win over everything.
reset_state
DRY_RUN=false
send_notification "$NOTIF_CONFIG" "false" "failover" "example.test" \
    "203.0.113.10" "198.51.100.20" "stubbed reason" >/dev/null 2>&1

if [[ -s "$SENT_LOG" ]]; then
    fail "a domain opted out still sends nothing" \
         "dispatched: $(tr '\n' ' ' < "$SENT_LOG")"
else
    pass "a domain opted out still sends nothing"
fi

# ─── 4. The dry-run is visible in the log ────────────────────────────────────

printf '\nDry-run is reported\n'

reset_state
: > "$LOG_FILE"
DRY_RUN=true
send_notification "$NOTIF_CONFIG" "true" "failback" "example.test" \
    "198.51.100.20" "203.0.113.10" "stubbed reason" >/dev/null 2>&1

if grep -q 'DRY-RUN' "$LOG_FILE" && grep -q 'failback' "$LOG_FILE"; then
    pass "the suppressed notification is logged as a dry-run"
else
    fail "the suppressed notification is logged as a dry-run" \
         "log did not record the suppressed failback notification"
fi

# Leave the sourced script's state as we found it. Read by send_notification in
# the sourced script, which ShellCheck cannot see from here.
# shellcheck disable=SC2034
DRY_RUN=false
unset -f send_telegram send_slack send_webhook

# ─── Summary ─────────────────────────────────────────────────────────────────

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
