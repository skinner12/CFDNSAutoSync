# TDD Evidence — Named Server References

Refactor of `domain.json` so each physical server is declared once and domains
reference it by name.

**Source plan:** none. Journeys were derived during this TDD run from the
request: define the server IPs once at the top and associate primary/backup
addresses with domains, so a VPS that changes address is not a many-line edit.

**Branch:** `refactor/named-servers` · **Version:** 1.4.3 → 1.5.0

---

## User journeys

1. As an operator, I want to define each server's IP once at the top of
   `domain.json`, so that re-addressing a VPS is a one-line edit instead of one
   edit per domain.
2. As an operator, I want domains to inherit a default primary/secondary pair,
   so that only the domains that differ carry their own settings.
3. As an operator, I want a domain to be able to reverse the two roles, because
   some domains are served primarily from the backup machine.
4. As an operator, I want my existing config to keep working untouched, so that
   I can deploy the new script before migrating the config.
5. As an operator, I want a mistyped server name to stop that domain rather than
   silently repoint it, because a wrong A record is worse than a skipped update.

---

## Task report

### 1. Resolve a domain's IPs from a named server map

Added `resolve_server_ip` and `is_valid_ipv4` to `cloudflare_dns_updater.sh` and
wired them into `main()`, replacing the two direct `jq -r '.primary_ip'` reads.

- **Validation command:** `bash tests/server_resolution_test.sh`
- **RED:** `22 run, 16 failed` — `resolve_server_ip` did not exist (`exit 127`),
  and `main()` passed a literal `null` to `update_cloudflare_dns`:

  ```
  FAIL    primary_server resolves through the servers map
            expected '203.0.113.10', but resolution failed (exit 127)
  FAIL    a domain with no IP fields inherits the default server
            expected inherits.example -> 203.0.113.10, got inherits.example -> null
  FAIL    one bad entry does not stop the remaining domains
            expected 3 updates, recorded 4
  ```

- **GREEN:** `22 run, 0 failed`
- **Guaranteed:** each role resolves in the documented precedence order; unknown
  names and malformed addresses are rejected rather than forwarded to Cloudflare.

### 2. Preserve the existing config format

Legacy `primary_ip`/`secondary_ip` remain step 2 of the resolution order, so no
config change is required to run the new script.

- **Validation command:** `bash tests/health_check_user_agent_test.sh`
- **Output:** `3 run, 0 failed, 0 skipped` — no regression in the existing suite.
- **Guaranteed:** a domain carrying inline IPs is updated exactly as before, and
  an absent `servers` map does not break resolution.

### 3. Confirm the real config migrates without behaviour change

A migrated copy of the live `domain.json` (9 domains, 2 servers) was generated in
a scratch directory and both configs were resolved through the script's own
resolver.

- **Validation command:** `diff` of `resolve_server_ip` output for every domain,
  old config vs migrated config.
- **Output:** identical for all 9 domains; `0` unresolved in either.
- **Guaranteed:** migrating the production config is a no-op for DNS behaviour.

### 4. Dry-run must not consume the notification cooldown

Found while dry-running the migrated config against the live setup: `--dry-run`
only guarded the DNS write inside `update_cloudflare_dns`, so `send_notification`
ran unconditionally and sent nine real Telegram alerts. Each also stamped a
cooldown timestamp, which would have suppressed the next genuine alert for that
domain and event for 30 minutes.

The alerts themselves are wanted — they make a dry-run an end-to-end check of the
channel configuration — so the chosen behaviour is *deliver, but never stamp the
cooldown*. Two RED/GREEN cycles ran here: the first suppressed notifications
entirely, then the requirement was refined to keep delivery and drop only the
cooldown side effect.

- **Validation command:** `bash tests/dry_run_notifications_test.sh`
- **RED (final requirement):** `12 run, 4 failed`

  ```
  FAIL    telegram is dispatched during a dry-run
            no telegram dispatch recorded
  FAIL    every dry-run in a row is delivered, none suppressed
            expected 3 telegram dispatches, got 0
  ```

- **GREEN:** `12 run, 0 failed`
- **Guaranteed:** a dry-run delivers on every enabled channel, never writes a
  cooldown file however many times it runs, and a genuine alert immediately
  afterwards is still delivered. Non-dry-run dispatch, the cooldown itself, and
  the per-domain opt-out are unchanged.

**Note on the alert content:** the `both_offline` conclusions in that run were a
false positive, not an outage. Direct-IP health checks returned HTTP 403 in
~0.12s from both servers for all nine domains while the domains themselves
answered HTTP 200, because the machine running the check is not in the origin
allow-list — see the comment at the failback branch in `cloudflare_dns_updater.sh`.
Run dry-runs from a whitelisted host for meaningful health results.

### 5. Lint

- **Validation command:** `shellcheck --severity=warning cloudflare_dns_updater.sh tests/*.sh`
- **Output:** clean (exit 0), matching the CI job in `.github/workflows/shellcheck.yml`.

---

## Test specification

| # | What is guaranteed | Test | Type | Result |
|---|--------------------|------|------|--------|
| 1 | `primary_server` resolves through the `servers` map | `server_resolution_test.sh:primary_server resolves through the servers map` | unit | PASS |
| 2 | `secondary_server` resolves through the `servers` map | `…:secondary_server resolves through the servers map` | unit | PASS |
| 3 | A domain may reverse the roles of the same two servers | `…:a domain may reverse the roles of the same two servers` | unit | PASS |
| 4 | Legacy `primary_ip` is still honoured | `…:legacy primary_ip is still honoured` | unit | PASS |
| 5 | Legacy `secondary_ip` is still honoured | `…:legacy secondary_ip is still honoured` | unit | PASS |
| 6 | An empty `servers` map does not break a legacy config | `…:an empty servers map does not break a legacy config` | unit | PASS |
| 7 | `primary_server` wins when both forms are present | `…:primary_server wins when both forms are present` | unit | PASS |
| 8 | Falls back to `defaults.primary_server` | `…:falls back to defaults.primary_server` | unit | PASS |
| 9 | Falls back to `defaults.secondary_server` | `…:falls back to defaults.secondary_server` | unit | PASS |
| 10 | A domain override beats the default | `…:a domain override beats the default` | unit | PASS |
| 11 | A legacy inline IP beats the default server | `…:a legacy inline IP beats the default server` | unit | PASS |
| 12 | `defaults` may also carry a literal IP | `…:defaults may also carry a literal IP` | unit | PASS |
| 13 | An unknown server name is an error, not a silent fallback | `…:an unknown server name is an error, not a silent fallback` | unit | PASS |
| 14 | A domain with no primary configured is an error | `…:a domain with no primary configured is an error` | unit | PASS |
| 15 | A non-IP value in the `servers` map is rejected | `…:a non-IP value in the servers map is rejected` | unit | PASS |
| 16 | An out-of-range octet is rejected | `…:an out-of-range octet is rejected` | unit | PASS |
| 17 | An empty server name is rejected | `…:an empty server name is rejected` | unit | PASS |
| 18 | A domain with no IP fields inherits the default server | `…:a domain with no IP fields inherits the default server` | integration | PASS |
| 19 | A domain may point primary at the backup server | `…:a domain may point primary at the backup server` | integration | PASS |
| 20 | A legacy-format domain is updated exactly as before | `…:a legacy-format domain is updated exactly as before` | integration | PASS |
| 21 | A domain naming an unknown server is skipped | `…:a domain naming an unknown server is skipped` | integration | PASS |
| 22 | One bad entry does not stop the remaining domains | `…:one bad entry does not stop the remaining domains` | integration | PASS |
| 23 | Health checks still send the identifying User-Agent | `health_check_user_agent_test.sh` (3 assertions) | integration + e2e | PASS |
| 24 | Telegram/Slack/webhook are dispatched during a dry-run | `dry_run_notifications_test.sh:{telegram,slack,webhook} is dispatched during a dry-run` | unit | PASS |
| 25 | A dry-run does not write a cooldown timestamp | `…:a dry-run does not write a cooldown timestamp` | unit | PASS |
| 26 | A real alert after a dry-run is still delivered | `…:a real alert after a dry-run is still delivered` | unit | PASS |
| 27 | Telegram/Slack/webhook dispatch when not in dry-run | `…:{telegram,slack,webhook} is dispatched when not in dry-run` | unit | PASS |
| 28 | A domain opted out still sends nothing | `…:a domain opted out still sends nothing` | unit | PASS |
| 29 | The dispatch is marked as a dry-run in the log | `…:the dispatch is marked as a dry-run in the log` | unit | PASS |
| 30 | Repeated dry-runs never stamp the cooldown | `…:repeated dry-runs never stamp the cooldown` | unit | PASS |
| 31 | Every dry-run in a row is delivered, none suppressed | `…:every dry-run in a row is delivered, none suppressed` | unit | PASS |

Integration cases 18–22 drive `main()` end to end against a synthetic config
with the network-facing functions stubbed, so they cover the per-domain subshell
loop and not just the resolver in isolation.

---

## Coverage and known gaps

There is no line-coverage tool in this Bash project; coverage is tracked by
behaviour instead. All four branches of the resolution order, both rejection
paths, and the skip-and-continue behaviour in `main()` are exercised.

Known gaps, all deliberate:

- **IPv6 is not supported.** `is_valid_ipv4` rejects it. The updater only manages
  `A` records, so an `AAAA` address was never valid input; previously it would
  have been forwarded to the Cloudflare API and rejected there instead.
- **No test asserts log wording.** Error messages are checked for exit status and
  stream (stderr), not text, so message wording can change without breaking tests.
- **The live `domain.json` is not migrated by this branch.** Equivalence was
  verified against a scratch copy (task 3); the production config is unchanged
  and continues to resolve through the legacy path.

---

## Merge evidence

If the three checkpoint commits are squashed, this is the record:

- `8955b21` — RED: `tests/server_resolution_test.sh` added, `22 run, 16 failed`,
  failing because `resolve_server_ip` was undefined.
- `3dbfa37` — GREEN: resolver implemented and wired into `main()`,
  `22 run, 0 failed`, existing suite `3 run, 0 failed`, shellcheck clean.
- `180b408` — docs: README, CLAUDE.md, ARCHITECTURE, TECHNICAL_REFERENCE and
  `domain.json.example` updated for the new format.
- `ce6cf82` — RED/GREEN: first cut, `--dry-run` suppressed notifications
  entirely. `8 run, 4 failed` → `8 run, 0 failed`.
- final commit — RED/GREEN: requirement refined to keep delivery and drop only
  the cooldown side effect. `12 run, 4 failed` → `12 run, 0 failed`.
