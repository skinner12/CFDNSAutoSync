#!/usr/bin/env bash
#
# Verifies that domains resolve their primary/secondary IPs from the top-level
# "servers" map instead of repeating the address inline.
#
# Background: nine domains shared two physical servers, so each address was
# written out eighteen times across primary_ip/secondary_ip. Re-addressing a VPS
# meant editing every entry by hand, and a single missed line silently pointed a
# domain at a dead host. Naming the servers once at the top of domain.json turns
# that into a one-line edit. Configs written in the old format must keep working
# untouched, so the script can be deployed before the config is migrated.
#
# Usage: bash tests/server_resolution_test.sh

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

# Sourcing only defines the functions; the entry point is guarded by a
# BASH_SOURCE check so the updater does not run here.
# shellcheck source=/dev/null
source "$TARGET"

# Keep the real log and cache untouched. Read by the sourced script, which
# ShellCheck cannot see from here.
# shellcheck disable=SC2034
LOG_FILE="$WORKDIR/test.log"
# shellcheck disable=SC2034
CACHE_DIR="$WORKDIR/cache"
# shellcheck disable=SC2034
NOTIFICATION_CACHE_DIR="$WORKDIR/notification_cache"
# shellcheck disable=SC2034
DOWNTIME_CACHE_DIR="$WORKDIR/downtime_cache"

SERVERS='{"vps-main":"203.0.113.10","vps-backup":"198.51.100.20"}'

# ─── Helpers ─────────────────────────────────────────────────────────────────

assert_resolves() {
    local label=$1 role=$2 config=$3 servers=$4 defaults=$5 expected=$6
    local got status

    got=$(resolve_server_ip "$role" "$config" "$servers" "$defaults" "test.example" 2>/dev/null)
    status=$?

    if [[ $status -ne 0 ]]; then
        fail "$label" "expected '$expected', but resolution failed (exit $status)"
    elif [[ "$got" != "$expected" ]]; then
        fail "$label" "expected '$expected', got '$got'"
    else
        pass "$label"
    fi
}

assert_rejects() {
    local label=$1 role=$2 config=$3 servers=$4 defaults=$5
    local got status

    got=$(resolve_server_ip "$role" "$config" "$servers" "$defaults" "test.example" 2>/dev/null)
    status=$?

    if [[ $status -eq 0 ]]; then
        fail "$label" "expected a failure, but it resolved to '$got'"
    else
        pass "$label"
    fi
}

# ─── 1. Named servers ────────────────────────────────────────────────────────

printf 'Server name resolution\n'

assert_resolves "primary_server resolves through the servers map" \
    "primary" '{"primary_server":"vps-main"}' "$SERVERS" '{}' "203.0.113.10"

assert_resolves "secondary_server resolves through the servers map" \
    "secondary" '{"secondary_server":"vps-backup"}' "$SERVERS" '{}' "198.51.100.20"

assert_resolves "a domain may reverse the roles of the same two servers" \
    "primary" '{"primary_server":"vps-backup"}' "$SERVERS" '{}' "198.51.100.20"

# ─── 2. Legacy literal IPs still work ────────────────────────────────────────

printf '\nLegacy inline IPs\n'

assert_resolves "legacy primary_ip is still honoured" \
    "primary" '{"primary_ip":"192.0.2.30"}' "$SERVERS" '{}' "192.0.2.30"

assert_resolves "legacy secondary_ip is still honoured" \
    "secondary" '{"secondary_ip":"192.0.2.40"}' "$SERVERS" '{}' "192.0.2.40"

assert_resolves "an empty servers map does not break a legacy config" \
    "primary" '{"primary_ip":"192.0.2.30"}' '{}' '{}' "192.0.2.30"

assert_resolves "primary_server wins when both forms are present" \
    "primary" '{"primary_server":"vps-main","primary_ip":"192.0.2.30"}' \
    "$SERVERS" '{}' "203.0.113.10"

# ─── 3. Defaults ─────────────────────────────────────────────────────────────

printf '\nShared defaults\n'

assert_resolves "falls back to defaults.primary_server" \
    "primary" '{"domain":"test.example"}' "$SERVERS" \
    '{"primary_server":"vps-main"}' "203.0.113.10"

assert_resolves "falls back to defaults.secondary_server" \
    "secondary" '{"domain":"test.example"}' "$SERVERS" \
    '{"secondary_server":"vps-backup"}' "198.51.100.20"

assert_resolves "a domain override beats the default" \
    "primary" '{"primary_server":"vps-backup"}' "$SERVERS" \
    '{"primary_server":"vps-main"}' "198.51.100.20"

assert_resolves "a legacy inline IP beats the default server" \
    "primary" '{"primary_ip":"192.0.2.30"}' "$SERVERS" \
    '{"primary_server":"vps-main"}' "192.0.2.30"

assert_resolves "defaults may also carry a literal IP" \
    "primary" '{"domain":"test.example"}' "$SERVERS" \
    '{"primary_ip":"192.0.2.50"}' "192.0.2.50"

# ─── 4. Invalid configuration is rejected, never guessed ─────────────────────

printf '\nInvalid configuration\n'

assert_rejects "an unknown server name is an error, not a silent fallback" \
    "primary" '{"primary_server":"typo-here","primary_ip":"192.0.2.30"}' "$SERVERS" '{}'

assert_rejects "a domain with no primary configured is an error" \
    "primary" '{"domain":"test.example"}' "$SERVERS" '{}'

assert_rejects "a non-IP value in the servers map is rejected" \
    "primary" '{"primary_server":"vps-broken"}' \
    '{"vps-broken":"not-an-ip"}' '{}'

assert_rejects "an out-of-range octet is rejected" \
    "primary" '{"primary_ip":"203.0.113.999"}' "$SERVERS" '{}'

assert_rejects "an empty server name is rejected" \
    "primary" '{"primary_server":""}' "$SERVERS" '{}'

# ─── 5. End to end through main() ────────────────────────────────────────────
#
# Resolution has to survive main()'s per-domain loop, which runs in a subshell.
# A domain whose server name is unknown must be skipped without aborting the
# run, so one bad entry cannot stop the remaining domains from being updated.

printf '\nEnd to end\n'

CONFIG_FILE="$WORKDIR/config.json"
UPDATES_LOG="$WORKDIR/updates.log"
: > "$UPDATES_LOG"

cat > "$CONFIG_FILE" <<'JSON'
{
  "servers": {
    "vps-main": "203.0.113.10",
    "vps-backup": "198.51.100.20"
  },
  "defaults": {
    "primary_server": "vps-main",
    "secondary_server": "vps-backup"
  },
  "domains": [
    {
      "domain": "inherits.example",
      "email": "ops@test.example",
      "api_key": "key",
      "zone_id": "zone",
      "excluded_subdomains": []
    },
    {
      "domain": "reversed.example",
      "primary_server": "vps-backup",
      "secondary_server": "vps-main",
      "email": "ops@test.example",
      "api_key": "key",
      "zone_id": "zone",
      "excluded_subdomains": []
    },
    {
      "domain": "legacy.example",
      "primary_ip": "192.0.2.30",
      "secondary_ip": "192.0.2.40",
      "email": "ops@test.example",
      "api_key": "key",
      "zone_id": "zone",
      "excluded_subdomains": []
    },
    {
      "domain": "typo.example",
      "primary_server": "vps-typo",
      "email": "ops@test.example",
      "api_key": "key",
      "zone_id": "zone",
      "excluded_subdomains": []
    }
  ]
}
JSON

# Stub every network-facing function so main() runs offline. update_cloudflare_dns
# records the IP it was asked to write, which is the observable outcome under test.
check_domain_online() { return 0; }
check_ip_online()     { return 0; }
check_ip_http()       { return 0; }
send_notification()   { return 0; }
update_cloudflare_dns() {
    printf '%s %s\n' "$4" "$5" >> "$UPDATES_LOG"
}

main >/dev/null 2>&1

unset -f check_domain_online check_ip_online check_ip_http send_notification
unset -f update_cloudflare_dns

assert_update() {
    local label=$1 domain=$2 expected=$3
    local got
    got=$(awk -v d="$domain" '$1 == d {print $2}' "$UPDATES_LOG")

    if [[ -z "$got" ]]; then
        fail "$label" "no DNS update recorded for $domain"
    elif [[ "$got" != "$expected" ]]; then
        fail "$label" "expected $domain -> $expected, got $domain -> $got"
    else
        pass "$label"
    fi
}

assert_update "a domain with no IP fields inherits the default server" \
    "inherits.example" "203.0.113.10"
assert_update "a domain may point primary at the backup server" \
    "reversed.example" "198.51.100.20"
assert_update "a legacy-format domain is updated exactly as before" \
    "legacy.example" "192.0.2.30"

if grep -q '^typo.example ' "$UPDATES_LOG"; then
    fail "a domain naming an unknown server is skipped" \
         "DNS was updated despite the unresolvable server name"
else
    pass "a domain naming an unknown server is skipped"
fi

if [[ "$(wc -l < "$UPDATES_LOG" | tr -d ' ')" -eq 3 ]]; then
    pass "one bad entry does not stop the remaining domains"
else
    fail "one bad entry does not stop the remaining domains" \
         "expected 3 updates, recorded $(wc -l < "$UPDATES_LOG" | tr -d ' ')"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
