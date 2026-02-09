# Cloudflare DNS Auto-Updater - Technical Reference

**Version**: 1.0.0
**Language**: Bash
**Dependencies**: jq, curl, bc
**License**: MIT

---

## Table of Contents

1. [Overview](#overview)
2. [Function Reference](#function-reference)
3. [CLI Reference](#cli-reference)
4. [Configuration Reference](#configuration-reference)
5. [File Paths Reference](#file-paths-reference)
6. [Exit Codes and Error Handling](#exit-codes-and-error-handling)
7. [Cloudflare API Reference](#cloudflare-api-reference)
8. [Quick Reference](#quick-reference)

---

## Overview

The Cloudflare DNS Auto-Updater is a bash script that monitors domain health and performs automatic DNS failover using Cloudflare's API. It supports two IP configurations (primary and secondary), health checks via HTTP and ICMP ping, and optional notifications via Telegram, Slack, or custom webhooks.

**Core Features**:
- Automatic failover from primary to secondary IP
- Automatic failback when primary recovers
- Per-subdomain exclusion rules
- Configurable health check timeouts and retry logic
- Notification dispatch with cooldown throttling
- Dry-run mode for testing
- Comprehensive logging with timestamps and severity levels

---

## Function Reference

### log_message

Writes timestamped log entries to both file and console with color-coded severity levels.

**Signature**:
```bash
log_message LEVEL MESSAGE
```

**Parameters**:
- `LEVEL` (string, required): Severity level. Valid values: `INFO`, `WARN`, `ERROR`, `CRITICAL`
- `MESSAGE` (string, required): Log message content

**Return Value**:
- Always returns 0 (success)

**Side Effects**:
- Appends entry to `$LOG_FILE` (default: `~/.cloudflare_dns_updater/dns_updater.log`)
- Prints to stdout with ANSI color codes:
  - `INFO`: Blue (034)
  - `WARN`: Yellow (033)
  - `ERROR`: Red (031)
  - `CRITICAL`: Bold Red (031;1)

**Example**:
```bash
log_message "INFO" "DNS update completed for example.com"
log_message "ERROR" "Failed to fetch DNS records: network timeout"
```

---

### should_send_notification

Checks cooldown timer to prevent notification spam for the same event type on the same domain.

**Signature**:
```bash
should_send_notification DOMAIN EVENT_TYPE [COOLDOWN_MINUTES]
```

**Parameters**:
- `DOMAIN` (string, required): Domain name (e.g., `example.com`)
- `EVENT_TYPE` (string, required): Event type (e.g., `failover`, `failback`, `both_offline`)
- `COOLDOWN_MINUTES` (int, optional): Minutes to wait before allowing next notification. Default: `$DEFAULT_NOTIFICATION_COOLDOWN` (30)

**Return Value**:
- 0: Notification should be sent (passed cooldown check)
- 1: Notification suppressed (still within cooldown period)

**Side Effects**:
- Creates/updates file: `$NOTIFICATION_CACHE_DIR/${domain}_${event_type}` containing Unix timestamp of last notification
- Creates `$NOTIFICATION_CACHE_DIR` if it doesn't exist

**Cache File Format**:
```
1707391234
```
(Unix timestamp in seconds)

**Example**:
```bash
if should_send_notification "example.com" "failover" 30; then
    send_notification "$notif_config" "$domain_notif_enabled" "failover" "example.com" ...
fi
```

---

### send_telegram

Sends notification via Telegram Bot API with formatted message and event emoji.

**Signature**:
```bash
send_telegram CONFIG EVENT_TYPE DOMAIN OLD_IP NEW_IP REASON TIMESTAMP HOSTNAME
```

**Parameters**:
- `CONFIG` (JSON string, required): Notification config object containing `channels.telegram` fields
- `EVENT_TYPE` (string, required): One of: `failover`, `failback`, `both_offline`
- `DOMAIN` (string, required): Domain name
- `OLD_IP` (string, required): Previous IP address
- `NEW_IP` (string, required): New IP address
- `REASON` (string, required): Human-readable reason for update
- `TIMESTAMP` (string, required): ISO 8601 timestamp (UTC)
- `HOSTNAME` (string, required): Hostname of machine running updater

**Return Value**:
- 0: Message sent successfully
- 1: Send failed (missing credentials, API error, or network failure)

**Side Effects**:
- Makes HTTP POST request to Telegram Bot API
- Logs result to `$LOG_FILE`

**Required Config Fields**:
- `config.channels.telegram.bot_token` (string): Telegram bot token
- `config.channels.telegram.chat_id` (string): Target Telegram chat ID

**API Endpoint**:
```
POST https://api.telegram.org/bot{bot_token}/sendMessage
```

**Request Format**:
```
chat_id={chat_id}
parse_mode=HTML
text={formatted_message}
```

**Event Icons**:
- `failover`: 🔴 (red circle)
- `failback`: 🟢 (green circle)
- `both_offline`: 🚨 (alarm)
- Other: 🔄 (refresh)

**Curl Options**:
- Connect timeout: 5 seconds
- Max time: 10 seconds
- Error output suppressed

**Example**:
```bash
send_telegram "$notif_config" "failover" "example.com" "1.1.1.1" "2.2.2.2" \
    "Domain offline" "2024-02-09 14:30:00 UTC" "server1"
```

---

### send_slack

Sends notification via Slack Incoming Webhook with color-coded attachment.

**Signature**:
```bash
send_slack CONFIG EVENT_TYPE DOMAIN OLD_IP NEW_IP REASON TIMESTAMP HOSTNAME
```

**Parameters**:
- Same as `send_telegram` except:
- `CONFIG` (JSON string, required): Must contain `channels.slack.webhook_url`

**Return Value**:
- 0: Message sent successfully
- 1: Send failed (missing URL, HTTP error, or network failure)

**Side Effects**:
- Makes HTTP POST request to Slack webhook
- Logs result to `$LOG_FILE`

**Required Config Fields**:
- `config.channels.slack.webhook_url` (string): Slack incoming webhook URL

**API Endpoint**:
```
POST {webhook_url}
```

**Payload Format**:
```json
{
  "attachments": [{
    "color": "#...",
    "title": "DNS {EVENT_TYPE}",
    "fields": [
      {"title": "Domain", "value": "...", "short": true},
      {"title": "Old IP", "value": "...", "short": true},
      {"title": "New IP", "value": "...", "short": true},
      {"title": "Reason", "value": "...", "short": false},
      {"title": "Time", "value": "...", "short": true},
      {"title": "Host", "value": "...", "short": true}
    ]
  }]
}
```

**Color Codes**:
- `failover`: #dc3545 (red)
- `failback`: #28a745 (green)
- `both_offline`: #ff0000 (bright red)
- Other: #007bff (blue)

**HTTP Success Criteria**:
- HTTP 200 response code

**Curl Options**:
- Connect timeout: 5 seconds
- Max time: 10 seconds
- Content-Type: application/json

---

### send_webhook

Sends JSON notification to custom webhook endpoint.

**Signature**:
```bash
send_webhook CONFIG EVENT_TYPE DOMAIN OLD_IP NEW_IP REASON TIMESTAMP HOSTNAME
```

**Parameters**:
- Same as `send_telegram` except:
- `CONFIG` (JSON string, required): Must contain `channels.webhook.url` and optionally `channels.webhook.method`

**Return Value**:
- 0: Message sent successfully
- 1: Send failed (missing URL, HTTP error, or network failure)

**Side Effects**:
- Makes HTTP request to webhook endpoint
- Logs result to `$LOG_FILE`

**Required Config Fields**:
- `config.channels.webhook.url` (string): Webhook endpoint URL
- `config.channels.webhook.method` (string, optional): HTTP method. Default: `POST`

**Payload Format**:
```json
{
  "event": "failover|failback|both_offline|...",
  "domain": "example.com",
  "old_ip": "1.1.1.1",
  "new_ip": "2.2.2.2",
  "reason": "Domain offline or too slow, switched to primary",
  "timestamp": "2024-02-09 14:30:00 UTC",
  "hostname": "server1"
}
```

**HTTP Success Criteria**:
- HTTP response code in range 200-299 (2xx)

**Curl Options**:
- Connect timeout: 5 seconds
- Max time: 10 seconds
- Content-Type: application/json
- Method: configurable (POST, PUT, etc.)

---

### send_notification

Dispatcher that evaluates global config, per-domain overrides, cooldown, and event filters before fanning out to enabled channels.

**Signature**:
```bash
send_notification NOTIF_CONFIG DOMAIN_NOTIF_ENABLED EVENT_TYPE DOMAIN OLD_IP NEW_IP REASON
```

**Parameters**:
- `NOTIF_CONFIG` (JSON string): Global notification config from `config.notifications`
- `DOMAIN_NOTIF_ENABLED` (string): Per-domain override. Values: `true`, `false`. If `false`, all notifications suppressed
- `EVENT_TYPE` (string, required): Event identifier (e.g., `failover`)
- `DOMAIN` (string, required): Domain name
- `OLD_IP` (string, required): Previous IP
- `NEW_IP` (string, required): New IP
- `REASON` (string, required): Human-readable reason

**Return Value**:
- Always 0 (fire-and-forget, never blocks DNS updates)

**Decision Logic** (evaluated in order):
1. If `NOTIF_CONFIG` is empty/null or `enabled != true`: return 0
2. If `DOMAIN_NOTIF_ENABLED == "false"`: return 0
3. If `EVENT_TYPE` not in `config.notifications.events` array: return 0
4. If cooldown not passed (via `should_send_notification`): return 0
5. Fan out to all enabled channels (Telegram, Slack, Webhook)

**Default Event List** (if not specified):
```json
["failover", "failback", "both_offline"]
```

**Side Effects**:
- May call `send_telegram`, `send_slack`, `send_webhook` asynchronously
- Updates notification cooldown cache
- All network calls are fire-and-forget (not blocking)

**Timestamp Format**:
```
2024-02-09 14:30:00 UTC
```
(Generated from `date -u '+%Y-%m-%d %H:%M:%S UTC'`)

**Hostname**:
- Extracted from `hostname -s` or defaults to `"unknown"`

**Example**:
```bash
send_notification "$notif_config" "$domain_notif_enabled" "failover" \
    "example.com" "1.1.1.1" "2.2.2.2" "Primary offline, failover to secondary"
```

---

### check_domain_online

Performs HTTP health check on domain with configurable timeout and retry logic. Validates both HTTP 200 status and response time threshold.

**Signature**:
```bash
check_domain_online DOMAIN [RESPONSE_TIMEOUT] [MAX_RETRIES] [RETRY_DELAY]
```

**Parameters**:
- `DOMAIN` (string, required): Domain name or FQDN (e.g., `example.com`)
- `RESPONSE_TIMEOUT` (int, optional): Maximum acceptable response time in seconds. Default: `$DEFAULT_RESPONSE_TIMEOUT` (3)
- `MAX_RETRIES` (int, optional): Number of retry attempts. Default: `$DEFAULT_MAX_RETRIES` (3)
- `RETRY_DELAY` (int, optional): Delay between retries in seconds. Default: `$DEFAULT_RETRY_DELAY` (2)

**Return Value**:
- 0: Domain is online and responsive (HTTP 200 within timeout)
- 1: Domain is offline, unresponsive, or too slow

**Side Effects**:
- Makes HTTPS GET requests to `https://{domain}/`
- Logs each attempt and final result to `$LOG_FILE`

**HTTP Request Details**:
- Protocol: HTTPS (enforced with `-L` follow redirects)
- Method: GET
- URL: `https://{domain}/`
- Connection timeout: 10 seconds (fixed)
- Response timeout: `response_timeout + 5` seconds (buffered)

**Curl Flags**:
- `-o /dev/null`: Discard response body
- `-s`: Silent mode
- `-L`: Follow redirects
- `-w "%{http_code} %{time_total}"`: Capture status code and total time
- `--connect-timeout 10`: Connection timeout
- `--max-time $((response_timeout + 5))`: Total max time

**Success Criteria** (all must be met):
- curl completes without error (non-empty status code and response time)
- HTTP status code == 200
- Response time <= `response_timeout` seconds

**Retry Behavior**:
- Retries if: connection fails, timeout exceeded, or non-200 status
- Sleeps `RETRY_DELAY` seconds between attempts
- No delay after final attempt

**Example**:
```bash
if check_domain_online "example.com" 3 3 2; then
    log_message "INFO" "Domain is healthy"
fi
```

---

### check_ip_online

Performs ICMP ping health check on IP address with retry logic.

**Signature**:
```bash
check_ip_online IP [MAX_RETRIES] [RETRY_DELAY]
```

**Parameters**:
- `IP` (string, required): IPv4 or IPv6 address (e.g., `1.1.1.1`)
- `MAX_RETRIES` (int, optional): Number of retry attempts. Default: `$DEFAULT_MAX_RETRIES` (3)
- `RETRY_DELAY` (int, optional): Delay between retries in seconds. Default: `$DEFAULT_RETRY_DELAY` (2)

**Return Value**:
- 0: IP is reachable (ping successful)
- 1: IP is unreachable (all retries failed)

**Side Effects**:
- Executes `ping` command (platform-specific)
- Logs each attempt and final result to `$LOG_FILE`

**Ping Command**:
```bash
ping -c 3 -W 2 {IP}
```
- `-c 3`: Send 3 ICMP echo requests
- `-W 2`: Wait timeout of 2 seconds per packet (macOS: `-W` in milliseconds as 2000)

**Retry Behavior**:
- Retries if: ping fails
- Sleeps `RETRY_DELAY` seconds between attempts
- No delay after final attempt

**Platform Notes**:
- macOS/BSD: `-W` timeout in milliseconds (2 seconds = 2000ms on some systems)
- Linux: `-W` timeout in milliseconds
- Behavior may vary by ping implementation

**Example**:
```bash
if check_ip_online "1.1.1.1" 3 2; then
    log_message "INFO" "IP is reachable"
fi
```

---

### update_cloudflare_dns

Updates all A records for a domain via Cloudflare API, with optional per-subdomain exclusions. Sets TTL=1 and proxied=true.

**Signature**:
```bash
update_cloudflare_dns EMAIL API_KEY ZONE_ID DOMAIN NEW_IP [EXCLUDED_SUBDOMAINS...]
```

**Parameters**:
- `EMAIL` (string, required): Cloudflare account email
- `API_KEY` (string, required): Cloudflare API key (not token)
- `ZONE_ID` (string, required): Cloudflare zone ID
- `DOMAIN` (string, required): Base domain name (e.g., `example.com`)
- `NEW_IP` (string, required): IP address to set for all records
- `EXCLUDED_SUBDOMAINS` (array of strings, optional): Subdomain parts to skip (e.g., `www` skips `www.example.com`)

**Return Value**:
- 0: All updates successful (or skipped)
- 1: Any update failed (network error, API error, or validation failure)

**Side Effects**:
- Fetches existing DNS records via GET request
- Updates each record via PUT request
- Writes new IP to cache file: `$CACHE_DIR/{domain}`
- Logs each record update to `$LOG_FILE`

**Cache File**:
- Path: `$CACHE_DIR/{domain}` (e.g., `~/.cloudflare_dns_updater/cache/example.com`)
- Content: Single line with IP address
- Written only after all updates complete successfully

**API Calls Made**:

1. **GET - Fetch DNS Records**:
```
GET /client/v4/zones/{zone_id}/dns_records?type=A
X-Auth-Email: {email}
X-Auth-Key: {api_key}
Content-Type: application/json
```

2. **PUT - Update DNS Record** (per record):
```
PUT /client/v4/zones/{zone_id}/dns_records/{record_id}
X-Auth-Email: {email}
X-Auth-Key: {api_key}
Content-Type: application/json

{
  "type": "A",
  "name": "{record_name}",
  "content": "{new_ip}",
  "ttl": 1,
  "proxied": true
}
```

**API Base Endpoint**:
```
https://api.cloudflare.com/client/v4
```

**Record Filtering**:
- Fetches only A records (`type=A` query parameter)
- Skips records already set to `NEW_IP`
- Skips records whose subdomain part matches `EXCLUDED_SUBDOMAINS`

**Subdomain Extraction**:
```bash
subdomain_part="${record_name%."$domain"}"
```
Example: For domain `example.com` and record `www.example.com`, extracts `www`

**Skip Conditions**:
1. Subdomain in excluded list: logs "Skipped {record_name} (excluded)"
2. Already set to target IP: logs "Skipped {record_name} (already set to {new_ip})"
3. Dry-run mode enabled: logs "[DRY-RUN] Would update {record_name}..."

**Error Handling**:
- If fetch fails: returns 1 and logs network/curl error
- If fetch returns `success=false` or has errors: returns 1
- If any update fails: returns 1 and logs specific error from API

**Curl Options**:
- Connect timeout: default (no explicit timeout for API calls)
- Timeout configured at script level for robustness

**Example**:
```bash
update_cloudflare_dns "user@example.com" "abc123def456" "zone123" \
    "example.com" "1.1.1.1" "no-update" "tmp"
```

---

### main

Primary orchestration function that loads configuration, iterates over domains, performs health checks, and coordinates failover/failback logic.

**Signature**:
```bash
main
```

**Parameters**: None

**Return Value**:
- 0: Execution completed (may have had individual domain failures)
- 1: Fatal error (config file missing, parse error)

**Side Effects**:
- Creates `$CACHE_DIR` and `$(dirname "$LOG_FILE")` if they don't exist
- Reads `$CONFIG_FILE` and parses JSON
- Calls health check functions for each domain
- Calls DNS update functions
- Calls notification functions
- Writes to log file and console

**Configuration Parsing**:

1. Reads global notification config from `config.notifications`
2. Reads domains array from `config.domains` (new format) or root array (legacy format)
3. Supports both old array format and new object format with backward compatibility

**Per-Domain Logic** (for each domain):

1. **Extract configuration fields**:
   - Required: `domain`, `primary_ip`, `secondary_ip`, `email`, `api_key`, `zone_id`
   - Optional: `excluded_subdomains`, `notifications_enabled`, `response_timeout`, `max_retries`, `retry_delay`

2. **Determine cached IP**:
   - Reads from `$CACHE_DIR/{domain}` or empty if file missing

3. **Check if domain is online**:

   **If domain is online**:
   - If currently on secondary IP and primary is up: failback to primary, send `failback` notification
   - Else if cached IP != primary IP and primary is up: update to primary
   - Else if cached IP != primary IP and primary is down: check secondary
     - If secondary is up: stay on secondary
     - If secondary is down: send `both_offline` critical alert
   - Else (cached IP == primary): verify primary is online, no action if healthy

   **If domain is offline/too slow**:
   - Check primary IP: if up, failover to primary, send `failover` notification
   - Else check secondary IP: if up, failover to secondary, send `failover` notification
   - Else: send `both_offline` critical alert

4. **Notification fields**:
   - Per-domain `notifications_enabled` field (default: true)
   - Uses global `notifications` config
   - Event types: `failover`, `failback`, `both_offline`

**Log Flow**:
```
[timestamp] [INFO] === DNS updater v1.0.0 started ===
[timestamp] [WARN] Running in DRY-RUN mode - no DNS changes will be made (if applicable)
[timestamp] [INFO] Processing domain: example.com (timeout: 3s, retries: 3)
[timestamp] [INFO] example.com is online. Checking IP consistency...
[timestamp] [INFO] IP 1.1.1.1 for example.com is valid and online. No action needed.
[timestamp] [INFO] === DNS updater v1.0.0 finished ===
```

**Timing**:
- HTTP checks: response_timeout + buffer (typically 8-10 seconds)
- Ping checks: ~6-10 seconds (3 pings at 2s each + retries)
- Total per domain: highly variable depending on health status

---

### parse_args

Parses command-line arguments and sets global variables.

**Signature**:
```bash
parse_args [ARGUMENTS...]
```

**Parameters**:
- All arguments passed to script (positional parameters)

**Return Value**:
- 0: Arguments parsed successfully
- 1: Unknown argument encountered (script exits)

**Side Effects**:
- Modifies global variables:
  - `DRY_RUN`: boolean (default: false)
  - `CONFIG_FILE`: path (default: domain.json)
  - `LOG_FILE`: path (default: ~/.cloudflare_dns_updater/dns_updater.log)
- May call `exit 0` for `--version` or `--help`
- May call `exit 1` for unknown arguments

**Argument Parsing**:
- Uses Bash case statement with shift
- Stops at first unknown argument and exits with error
- Arguments are position-independent (can appear in any order)

**Example Behavior**:
```bash
./cloudflare_dns_updater.sh --config myconfig.json --dry-run
# Sets: CONFIG_FILE="myconfig.json", DRY_RUN=true
```

---

## CLI Reference

### Usage

```bash
./cloudflare_dns_updater.sh [OPTIONS]
```

### Options

| Flag | Argument | Default | Description |
|------|----------|---------|-------------|
| `--dry-run` | None | false | Simulate updates without making DNS changes. Logs intended actions with "[DRY-RUN]" prefix. |
| `--config` | FILE | `domain.json` | Path to JSON configuration file. Can be absolute or relative. |
| `--log-file` | FILE | `~/.cloudflare_dns_updater/dns_updater.log` | Path to log file. Directory created if missing. |
| `--version` | None | N/A | Display version number and exit. |
| `--help` | None | N/A | Display help message and exit. |

### Examples

**Basic execution with default config**:
```bash
./cloudflare_dns_updater.sh
```
Uses `domain.json` in current directory, logs to `~/.cloudflare_dns_updater/dns_updater.log`

**Dry-run to test configuration**:
```bash
./cloudflare_dns_updater.sh --dry-run
```
Simulates all DNS updates without making actual changes

**Custom config and log file**:
```bash
./cloudflare_dns_updater.sh --config /etc/dns-updater/config.json --log-file /var/log/dns-updater.log
```

**Dry-run with custom config**:
```bash
./cloudflare_dns_updater.sh --config ./test-config.json --dry-run
```

**Check version**:
```bash
./cloudflare_dns_updater.sh --version
# Output: cloudflare_dns_updater v1.0.0
```

**View help**:
```bash
./cloudflare_dns_updater.sh --help
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (or help/version displayed) |
| 1 | Error (missing dependency, config file not found, parse error, unknown argument) |

---

## Configuration Reference

### File Format

JSON object with top-level `notifications` (global) and `domains` array.

### Backward Compatibility

The script supports two configuration formats:

**New Format** (Recommended):
```json
{
  "notifications": { ... },
  "domains": [ ... ]
}
```

**Legacy Format** (Still supported):
```json
[ ... ]
```
(Root array of domain objects, no global notifications)

### Global Configuration

#### notifications

Top-level block applied to all domains unless overridden. Optional.

**Type**: Object

**Fields**:

| Field | Type | Default | Required | Description |
|-------|------|---------|----------|-------------|
| `enabled` | boolean | false | No | Enable/disable all notifications globally |
| `events` | array of strings | `["failover", "failback", "both_offline"]` | No | Event types that trigger notifications |
| `cooldown_minutes` | integer | 30 | No | Minutes to wait before sending another notification for same event type on same domain |
| `channels` | object | N/A | No | Notification channels configuration |

**Example**:
```json
{
  "notifications": {
    "enabled": true,
    "events": ["failover", "failback", "both_offline"],
    "cooldown_minutes": 30,
    "channels": { ... }
  }
}
```

---

#### channels

Container for notification channel configurations.

**Type**: Object

**Fields**:
- `telegram`: Telegram notification settings
- `slack`: Slack notification settings
- `webhook`: Generic webhook notification settings

---

#### channels.telegram

**Type**: Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `enabled` | boolean | No | Enable Telegram notifications |
| `bot_token` | string | Yes (if enabled) | Telegram bot token from @BotFather |
| `chat_id` | string | Yes (if enabled) | Target Telegram chat/group/user ID |

**Example**:
```json
{
  "telegram": {
    "enabled": true,
    "bot_token": "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11",
    "chat_id": "-1001234567890"
  }
}
```

**Notes**:
- `bot_token`: Format is `{numeric_id}:{alphanumeric_token}`
- `chat_id`: Can be positive (user/channel) or negative (group, prefixed with -100)
- Both fields must be non-empty and not "null" to enable

---

#### channels.slack

**Type**: Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `enabled` | boolean | No | Enable Slack notifications |
| `webhook_url` | string | Yes (if enabled) | Slack Incoming Webhook URL |

**Example**:
```json
{
  "slack": {
    "enabled": false,
    "webhook_url": "https://hooks.slack.com/services/T00/B00/xxx"
  }
}
```

**Notes**:
- `webhook_url`: Must be valid HTTPS URL starting with `https://hooks.slack.com/`
- URL must be non-empty and not "null" to function

---

#### channels.webhook

**Type**: Object

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `enabled` | boolean | No | N/A | Enable custom webhook notifications |
| `url` | string | Yes (if enabled) | N/A | HTTP/HTTPS endpoint URL |
| `method` | string | No | `POST` | HTTP method (POST, PUT, PATCH, etc.) |

**Example**:
```json
{
  "webhook": {
    "enabled": true,
    "url": "https://your-endpoint.com/notify",
    "method": "POST"
  }
}
```

**Notes**:
- `url`: Must be non-empty and valid HTTP/HTTPS URL
- `method`: Case-sensitive, standard HTTP methods
- Accepts 2xx response codes as success

---

### Domain Configuration

#### domains

Array of domain configurations. Each entry represents a domain to monitor.

**Type**: Array of Objects

**Example**:
```json
{
  "domains": [
    { ... domain 1 ... },
    { ... domain 2 ... }
  ]
}
```

---

#### Domain Object Fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `domain` | string | Yes | N/A | Base domain name (e.g., `example.com`) |
| `primary_ip` | string | Yes | N/A | Primary IP address for failover |
| `secondary_ip` | string | Yes | N/A | Secondary IP address for failback |
| `email` | string | Yes | N/A | Cloudflare account email |
| `api_key` | string | Yes | N/A | Cloudflare API key (not token) |
| `zone_id` | string | Yes | N/A | Cloudflare zone ID for domain |
| `excluded_subdomains` | array of strings | No | [] | Subdomain parts to exclude from updates |
| `notifications_enabled` | boolean | No | true | Per-domain override to disable notifications |
| `response_timeout` | integer | No | 3 | HTTP response time threshold in seconds |
| `max_retries` | integer | No | 3 | Number of health check retries |
| `retry_delay` | integer | No | 2 | Seconds to wait between retries |

---

#### domain

Domain name to monitor and update.

**Type**: String

**Format**: FQDN without protocol (e.g., `example.com`, not `https://example.com`)

**Example**:
```json
"domain": "example.com"
```

**Notes**:
- Used in health checks as `https://{domain}/`
- Must be publicly resolvable and accessible via HTTPS
- Used to extract subdomain parts for exclusion matching

---

#### primary_ip

Primary IP address for this domain.

**Type**: String (IPv4 or IPv6)

**Example**:
```json
"primary_ip": "1.1.1.1"
```

**Notes**:
- Should be publicly routable
- Used in failover decision logic
- Must be reachable for health checks (ping)
- Updated to DNS records when primary recovers or during initial failover

---

#### secondary_ip

Secondary/backup IP address for this domain.

**Type**: String (IPv4 or IPv6)

**Example**:
```json
"secondary_ip": "1.2.3.4"
```

**Notes**:
- Fallback when primary is offline
- Used in automatic failback logic
- Must be reachable for health checks
- Should represent different infrastructure/location from primary

---

#### email

Cloudflare account email address for API authentication.

**Type**: String

**Example**:
```json
"email": "user@example.com"
```

**Notes**:
- Must match account associated with API key
- Used in `X-Auth-Email` header for all Cloudflare API calls
- Required for API authentication

---

#### api_key

Cloudflare Global API Key (not API Token).

**Type**: String

**Example**:
```json
"api_key": "abc123def456ghi789jkl012mno345pq"
```

**Notes**:
- Get from Cloudflare account settings (My Profile > API Tokens > Global API Key)
- Not an OAuth token or scoped token
- Used in `X-Auth-Key` header
- Should be treated as sensitive (don't commit to version control)

---

#### zone_id

Cloudflare Zone ID for the domain.

**Type**: String

**Example**:
```json
"zone_id": "d23223d23d4f1234334f34134f1134f"
```

**Notes**:
- Found in Cloudflare dashboard for the zone
- Used in API endpoints: `/zones/{zone_id}/dns_records`
- Required for DNS record updates

---

#### excluded_subdomains

Subdomain parts to skip during DNS updates.

**Type**: Array of Strings

**Example**:
```json
"excluded_subdomains": ["no-update", "tmp"]
```

**Behavior**:
- For domain `example.com` with record `no-update.example.com`:
  - Subdomain part extracted: `no-update`
  - Matches exclusion: record skipped
- For record `api.no-update.example.com`:
  - Subdomain part extracted: `api.no-update`
  - Does NOT match: record updated (requires exact match)

**Notes**:
- Empty array means update all subdomains
- Matching is exact string comparison
- Useful for preserving special-purpose records (monitoring, status pages)

---

#### notifications_enabled

Per-domain override for notification delivery.

**Type**: Boolean

**Default**: `true`

**Example**:
```json
"notifications_enabled": false
```

**Behavior**:
- If `false`: all notifications suppressed for this domain, regardless of global settings
- If `true` (or omitted): notifications follow global configuration
- Overrides all global notification settings

**Notes**:
- Domain-level setting only; cannot enable notifications if global setting disables them
- Useful for silencing non-critical domains

---

#### response_timeout

HTTP response time threshold for domain health checks.

**Type**: Integer (seconds)

**Default**: `3`

**Example**:
```json
"response_timeout": 5
```

**Behavior**:
- Domain health check considers response taking > timeout as failure
- Curl max-time set to `response_timeout + 5` seconds (buffer for curl processing)
- Retried up to `max_retries` times

**Notes**:
- Lower values (1-2s): faster failover, but may trigger on slow networks
- Higher values (5-10s): more tolerant, but slower to detect real outages
- Recommended: 3-5 seconds for most use cases

---

#### max_retries

Number of health check retry attempts before marking as offline.

**Type**: Integer

**Default**: `3`

**Example**:
```json
"max_retries": 5
```

**Behavior**:
- Total attempts: `max_retries` (no +1)
- If first attempt fails, retries `max_retries - 1` additional times
- Example with `max_retries: 3`: attempts 1, 2, 3 (total 3 checks)

**Notes**:
- Minimum recommended: 2 (avoid flapping on single transient failure)
- Maximum reasonable: 5-10 (script can become slow)
- Each retry delayed by `retry_delay` seconds

---

#### retry_delay

Seconds to wait between health check retries.

**Type**: Integer (seconds)

**Default**: `2`

**Example**:
```json
"retry_delay": 3
```

**Behavior**:
- Sleeps `retry_delay` seconds after each failed attempt
- No sleep after final (successful or last failed) attempt

**Notes**:
- Lower values (1-2s): faster failover detection
- Higher values (3-5s): more time for transient issues to resolve
- Total wait time: `(max_retries - 1) * retry_delay` if all fail

---

### Configuration Examples

**Minimal Configuration** (single domain, no notifications):
```json
{
  "domains": [
    {
      "domain": "example.com",
      "primary_ip": "1.1.1.1",
      "secondary_ip": "1.2.3.4",
      "email": "user@cloudflare.com",
      "api_key": "abc123def456",
      "zone_id": "zone123"
    }
  ]
}
```

**Full Configuration** (multiple domains, all notifications):
```json
{
  "notifications": {
    "enabled": true,
    "events": ["failover", "failback", "both_offline"],
    "cooldown_minutes": 30,
    "channels": {
      "telegram": {
        "enabled": true,
        "bot_token": "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11",
        "chat_id": "-1001234567890"
      },
      "slack": {
        "enabled": true,
        "webhook_url": "https://hooks.slack.com/services/T00/B00/xxx"
      },
      "webhook": {
        "enabled": true,
        "url": "https://monitoring.example.com/alert",
        "method": "POST"
      }
    }
  },
  "domains": [
    {
      "domain": "api.example.com",
      "primary_ip": "1.1.1.1",
      "secondary_ip": "1.2.3.4",
      "email": "user@cloudflare.com",
      "api_key": "abc123def456",
      "zone_id": "zone123",
      "excluded_subdomains": ["tmp", "dev"],
      "notifications_enabled": true,
      "response_timeout": 3,
      "max_retries": 3,
      "retry_delay": 2
    },
    {
      "domain": "status.example.com",
      "primary_ip": "2.2.2.2",
      "secondary_ip": "2.3.4.5",
      "email": "user@cloudflare.com",
      "api_key": "abc123def456",
      "zone_id": "zone456",
      "notifications_enabled": false
    }
  ]
}
```

**Legacy Format** (still supported):
```json
[
  {
    "domain": "example.com",
    "primary_ip": "1.1.1.1",
    "secondary_ip": "1.2.3.4",
    "email": "user@cloudflare.com",
    "api_key": "abc123def456",
    "zone_id": "zone123"
  }
]
```
(No global notifications, no per-domain overrides)

---

## File Paths Reference

### Default Paths

All default paths use `$HOME` as base directory.

#### Cache Directory

**Path**: `~/.cloudflare_dns_updater/cache/`

**Purpose**: Stores cached IP addresses for each domain

**Files**:
- `{domain}` (no extension): Plain text file containing single IP address
- Example: `cache/example.com` contains `1.1.1.1`

**Creation**: Automatic, created on first write

**Lifetime**: Persistent across script runs (survives until manually deleted)

**Example Usage**:
```bash
cat ~/.cloudflare_dns_updater/cache/example.com
# Output: 1.1.1.1
```

---

#### Notification Cache Directory

**Path**: `~/.cloudflare_dns_updater/notification_cache/`

**Purpose**: Stores last notification timestamp for cooldown enforcement

**Files**:
- `{domain}_{event_type}` (no extension): Plain text file containing Unix timestamp
- Example: `notification_cache/example.com_failover` contains `1707391234`

**Creation**: Automatic on first notification

**Lifetime**: Persistent until manually deleted

**Cleanup**: No automatic cleanup (manual recommended for old entries)

**Example Usage**:
```bash
cat ~/.cloudflare_dns_updater/notification_cache/example.com_failover
# Output: 1707391234
```

---

#### Log File

**Path**: `~/.cloudflare_dns_updater/dns_updater.log`

**Purpose**: Persistent log of all script activity

**Format**:
```
[YYYY-MM-DD HH:MM:SS] [LEVEL] Message
```

**Levels**: INFO, WARN, ERROR, CRITICAL

**Creation**: Automatic, created on first write

**Rotation**: None (manual rotation required or external tooling)

**Access**: Append-only (never truncated)

**Typical Size**:
- ~500 KB per month (depending on execution frequency)
- Can grow large with frequent runs

**Example Output**:
```
[2024-02-09 14:30:00] [INFO] === DNS updater v1.0.0 started ===
[2024-02-09 14:30:05] [INFO] example.com is online (HTTP 200, 1.234s)
[2024-02-09 14:30:10] [INFO] IP 1.1.1.1 for example.com is valid and online. No action needed.
[2024-02-09 14:30:10] [INFO] === DNS updater v1.0.0 finished ===
```

---

#### Configuration File

**Default Path**: `./domain.json` (current directory)

**Customizable**: Via `--config` CLI flag

**Format**: JSON (see Configuration Reference)

**Example Paths**:
```bash
./domain.json                           # Current directory
/etc/dns-updater/config.json            # System config
$HOME/.config/dns-updater/config.json   # User config
/opt/dns-updater/domains.json           # Application directory
```

---

### Directory Structure

```
~/.cloudflare_dns_updater/
├── cache/
│   ├── example.com
│   ├── api.example.com
│   └── status.example.com
├── notification_cache/
│   ├── example.com_failover
│   ├── example.com_failback
│   ├── api.example.com_failover
│   └── status.example.com_both_offline
└── dns_updater.log
```

---

### Custom Path Configuration

All paths can be overridden via CLI flags:

```bash
./cloudflare_dns_updater.sh \
    --config /etc/myapp/config.json \
    --log-file /var/log/myapp/dns-updater.log
```

**Note**: Cache directories are hardcoded and cannot be customized via CLI. To use custom cache paths, modify the script directly or use environment variable substitution in the configuration.

---

## Exit Codes and Error Handling

### Script Exit Codes

| Code | Trigger | Example |
|------|---------|---------|
| 0 | Normal completion or help/version displayed | Main loop completes |
| 1 | Fatal error preventing execution | Missing config file, unknown CLI argument, missing dependency |

### Error Conditions

#### Missing Dependencies

**Condition**: `jq`, `curl`, or `bc` not installed

**Exit Code**: 1

**Log Output**: stderr only
```
jq is not installed. Please install jq to run this script.
```

**Handling**: Script checks all dependencies before any other operations

---

#### Missing Configuration File

**Condition**: `$CONFIG_FILE` does not exist

**Exit Code**: 1

**Log Output**:
```
[2024-02-09 14:30:00] [ERROR] Config file not found: domain.json
```

**Handling**: Script logs error and returns from main function

---

#### Invalid Configuration Format

**Condition**: JSON parse error or missing required fields

**Exit Code**: 0 (script completes, but domain skipped)

**Log Output**:
```
[2024-02-09 14:30:00] [ERROR] Failed to parse config file or no domains configured: domain.json
```

**Handling**: Script logs error and skips entire processing loop if no domains parsed

---

#### Network Errors (Health Checks)

**Condition**: HTTPS GET or ping fails

**Exit Code**: 0 (script continues)

**Log Output**:
```
[2024-02-09 14:30:00] [WARN] Attempt 1/3: Failed to connect to example.com
[2024-02-09 14:30:02] [WARN] Attempt 2/3: Failed to connect to example.com
[2024-02-09 14:30:04] [ERROR] example.com offline/unhealthy after 3 attempts
```

**Handling**: Retries up to `max_retries` times, then triggers failover logic

---

#### Cloudflare API Errors

**Condition**: API returns `success: false` or has errors array

**Exit Code**: 0 (script continues)

**Log Output**:
```
[2024-02-09 14:30:00] [ERROR] Failed to fetch DNS records for example.com: [error details]
```

**Handling**: Logs error and skips domain (doesn't update DNS for that domain)

---

#### HTTP Response Code Errors

**Condition**: Domain returns non-200 status

**Exit Code**: 0 (script continues)

**Log Output**:
```
[2024-02-09 14:30:00] [WARN] Attempt 1/3: example.com returned HTTP 503 (1.234s)
```

**Handling**: Treated as offline, triggers failover logic

---

#### Timeout Errors

**Condition**: Domain responds but takes > response_timeout seconds

**Exit Code**: 0 (script continues)

**Log Output**:
```
[2024-02-09 14:30:00] [WARN] Attempt 1/3: example.com responded in 5.234s (threshold: 3s)
```

**Handling**: Treated as offline, retried or triggers failover

---

#### Notification Delivery Failures

**Condition**: Telegram, Slack, or webhook send fails

**Exit Code**: 0 (script continues, DNS updates unaffected)

**Log Output**:
```
[2024-02-09 14:30:00] [ERROR] Telegram notification failed for example.com: [error]
```

**Handling**: Fire-and-forget, logged but not blocking. Never affects DNS updates.

---

#### Both IPs Offline

**Condition**: All health checks fail for both primary and secondary

**Exit Code**: 0 (script continues)

**Log Output**:
```
[2024-02-09 14:30:00] [CRITICAL] Both IPs offline for example.com. Urgent attention required!
```

**Handling**: Sends `both_offline` notification (if enabled). Does NOT update DNS (remains on last known IP).

---

### Error Recovery Strategy

The script is designed to be fault-tolerant:

1. **Per-Domain Isolation**: Failure on one domain doesn't affect others
2. **No Cascading Failures**: API errors don't stop health checks
3. **Notification Non-Blocking**: Failed notifications never prevent DNS updates
4. **Graceful Degradation**: Script continues with reduced functionality if errors occur
5. **Comprehensive Logging**: All errors logged with context for debugging

---

## Cloudflare API Reference

### Base Endpoint

```
https://api.cloudflare.com/client/v4
```

### Authentication

All requests use HTTP headers:

```
X-Auth-Email: {email}
X-Auth-Key: {api_key}
Content-Type: application/json
```

**Notes**:
- Uses Global API Key (not OAuth token or API token)
- Email must match API key's account
- API key from Cloudflare account settings (My Profile > API Tokens > Global API Key)

---

### GET - List DNS Records

Retrieves all A records for a zone.

**Endpoint**:
```
GET /zones/{zone_id}/dns_records?type=A
```

**Headers**:
```
X-Auth-Email: {email}
X-Auth-Key: {api_key}
Content-Type: application/json
```

**Query Parameters**:
- `type=A`: Filter to A records only

**Response Format**:
```json
{
  "success": true,
  "errors": [],
  "result": [
    {
      "id": "record_id_1",
      "type": "A",
      "name": "example.com",
      "content": "1.1.1.1",
      "ttl": 1,
      "proxied": true,
      "created_on": "2024-01-01T00:00:00Z",
      "modified_on": "2024-02-01T00:00:00Z"
    },
    {
      "id": "record_id_2",
      "type": "A",
      "name": "www.example.com",
      "content": "1.1.1.1",
      "ttl": 1,
      "proxied": true,
      "created_on": "2024-01-01T00:00:00Z",
      "modified_on": "2024-02-01T00:00:00Z"
    }
  ],
  "result_info": {
    "page": 1,
    "per_page": 20,
    "total_pages": 1,
    "count": 2,
    "total_count": 2
  }
}
```

**Parsing Logic**:
```bash
# Check success
jq -r '.success'  # Expect: "true"

# Check errors
jq -r '.errors | length'  # Expect: 0

# Extract records
jq '.result[] | {id, name, content}'
```

---

### PUT - Update DNS Record

Updates a single DNS record.

**Endpoint**:
```
PUT /zones/{zone_id}/dns_records/{record_id}
```

**Headers**:
```
X-Auth-Email: {email}
X-Auth-Key: {api_key}
Content-Type: application/json
```

**Request Body**:
```json
{
  "type": "A",
  "name": "example.com",
  "content": "1.1.1.1",
  "ttl": 1,
  "proxied": true
}
```

**Body Fields**:
- `type`: Always "A" for A records
- `name`: Full record name (FQDN)
- `content`: IP address to set
- `ttl`: Time to live in seconds (1 = auto)
- `proxied`: Cloudflare proxy status (true = orange cloud, false = gray cloud)

**Response Format**:
```json
{
  "success": true,
  "errors": [],
  "result": {
    "id": "record_id_1",
    "type": "A",
    "name": "example.com",
    "content": "1.1.1.1",
    "ttl": 1,
    "proxied": true,
    "created_on": "2024-01-01T00:00:00Z",
    "modified_on": "2024-02-09T14:30:00Z"
  }
}
```

**Success Criteria**:
- `success == true`
- `errors` array is empty
- `status_code == 200`

**Error Response Format**:
```json
{
  "success": false,
  "errors": [
    {
      "code": 7003,
      "message": "Could not route to /zones/invalid_zone_id/dns_records/..., verify the resource exists"
    }
  ],
  "result": null
}
```

---

### Curl Command Examples

**Fetch DNS Records**:
```bash
curl -s -X GET "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?type=A" \
  -H "X-Auth-Email: {email}" \
  -H "X-Auth-Key: {api_key}" \
  -H "Content-Type: application/json"
```

**Update DNS Record**:
```bash
curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}" \
  -H "X-Auth-Email: {email}" \
  -H "X-Auth-Key: {api_key}" \
  -H "Content-Type: application/json" \
  -d '{"type":"A","name":"example.com","content":"1.1.1.1","ttl":1,"proxied":true}'
```

---

### Common API Error Codes

| Code | Message | Cause |
|------|---------|-------|
| 7003 | Could not route to resource | Invalid zone_id or record_id |
| 9103 | Invalid request headers | Missing or malformed auth headers |
| 6003 | Invalid request body | Malformed JSON or invalid parameters |
| 1004 | Invalid API token | API key is incorrect or expired |
| 6102 | Invalid value for name | Record name doesn't belong to zone |

---

### Rate Limiting

Cloudflare API rate limits:
- Default: 1,200 requests per 5 minutes
- Script makes 1 fetch + N updates per domain (N = number of records)
- Typical per domain: ~5-20 requests

No explicit rate limit handling in script (relies on Cloudflare to return 429 status, treated as error).

---

### API Call Locations in Script

1. **Line 366-372**: GET `/zones/{zone_id}/dns_records?type=A`
   - Fetches all A records for domain
   - Called once per domain per execution

2. **Line 414-418**: PUT `/zones/{zone_id}/dns_records/{record_id}`
   - Updates single record
   - Called once per record needing update
   - Looped for each A record (except excluded)

---

## Quick Reference

### Failover Decision Tree

```
Domain online and responsive?
├─ YES: Check IP consistency
│  ├─ On secondary, primary online? → Failback to primary
│  ├─ Cached IP != primary, primary online? → Update to primary
│  ├─ Cached IP != primary, primary offline, secondary online? → Stay on secondary
│  ├─ Cached IP != primary, both offline? → Alert both_offline
│  └─ Cached IP == primary? → No action
│
└─ NO: Initiate failover
   ├─ Primary online? → Failover to primary
   ├─ Primary offline, secondary online? → Failover to secondary
   └─ Both offline? → Alert both_offline (no DNS change)
```

---

### Notification Event Types

| Event | Trigger | Notification Sent |
|-------|---------|-------------------|
| `failover` | Domain offline, switched to different IP | Yes |
| `failback` | Primary recovered while on secondary | Yes |
| `both_offline` | Both primary and secondary unreachable | Yes |

**Default Events** (if not configured):
```json
["failover", "failback", "both_offline"]
```

---

### Health Check Decision Matrix

| Check | Retry | Timeout | Success Criteria |
|-------|-------|---------|------------------|
| HTTP (domain) | Yes (max_retries) | response_timeout | HTTP 200 + response <= timeout |
| Ping (IP) | Yes (max_retries) | Fixed (2s per packet) | Ping reply received |

---

### CLI Quick Commands

```bash
# Dry-run test
./cloudflare_dns_updater.sh --dry-run

# Custom config
./cloudflare_dns_updater.sh --config /etc/config.json

# View version
./cloudflare_dns_updater.sh --version

# Full example with dry-run
./cloudflare_dns_updater.sh --config ./test.json --log-file ./test.log --dry-run
```

---

### Log Levels

- **INFO**: Normal operation (domain checks, updates, notifications sent)
- **WARN**: Potentially concerning but non-fatal (retries, timeouts, skipped records)
- **ERROR**: Error condition affecting one domain or operation
- **CRITICAL**: Severe condition affecting availability (both IPs offline)

---

### Default Configuration Values

| Setting | Default |
|---------|---------|
| Response timeout | 3 seconds |
| Max retries | 3 attempts |
| Retry delay | 2 seconds |
| Notification cooldown | 30 minutes |
| DNS record TTL | 1 (Cloudflare auto-TTL) |
| DNS record proxied | true |
| Log format | [YYYY-MM-DD HH:MM:SS] [LEVEL] Message |

---

### Performance Characteristics

**Time per Domain** (worst case):
- Domain offline check: 3s * 3 retries + 2s delays = ~10-15s
- IP ping checks: ~6-9s (3 pings at 2-3s per attempt)
- DNS API fetch: 1-2s
- DNS record updates: ~1-2s per record
- **Total**: ~20-30s per domain (if offline with retries)

**Time per Domain** (best case):
- Domain online check: 1-2s
- No IP checks needed
- No DNS updates
- **Total**: 1-2s per domain

**Script Overhead**:
- Config parsing: <100ms
- Logging: <1ms per message
- Notification dispatch: <100ms per channel (fire-and-forget)

---

**Document Version**: 1.0.0
**Last Updated**: 2024-02-09
**Script Version**: 1.0.0
