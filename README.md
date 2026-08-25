# Cloudflare DNS Update Script

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Release](https://img.shields.io/github/v/release/skinner12/CFDNSAutoSync)](https://github.com/skinner12/CFDNSAutoSync/releases)
[![ShellCheck](https://github.com/skinner12/CFDNSAutoSync/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/skinner12/CFDNSAutoSync/actions/workflows/shellcheck.yml)
[![Docker](https://img.shields.io/badge/docker-ghcr.io-blue)](https://github.com/skinner12/CFDNSAutoSync/pkgs/container/CFDNSAutoSync)

## Overview
This script is designed to automate the process of updating DNS records on Cloudflare for specified domains. It checks the online status and response time of the domain, verifies IP consistency, and updates DNS records if necessary. It handles primary and secondary IP failovers with automatic failback, and sends notifications (Telegram, Slack, Webhook) when IP changes occur.

## Features
- **Response Time Detection**: Fails over if the server responds too slowly (configurable threshold, default 3s), not just when it's completely offline.
- **Retry Logic**: Retries health checks multiple times before declaring failure, avoiding false positives from transient network issues.
- **Auto Failback**: Automatically switches back to the primary IP when it recovers, even while the domain is still online on the secondary IP.
- **Failover Handling**: Switches to a secondary IP if the primary IP is offline or too slow.
- **Notifications**: Optional alerts via Telegram, Slack, or generic Webhook on failover, failback, and critical events. Global configuration with per-domain opt-out and cooldown to prevent spam.
- **DNS Record Validation**: Checks current DNS record content before updating, skipping records already at the target IP.
- **Dry-Run Mode**: Simulate updates without making actual DNS changes using `--dry-run`.
- **Timestamped Logging**: All operations are logged with timestamps and severity levels (INFO/WARN/ERROR/CRITICAL) to both console and log file.
- **Per-Domain Configuration**: Each domain can have its own response timeout, retry count, and retry delay. Notifications can be disabled per domain.
- **Persistent Cache**: IP cache stored in `~/.cloudflare_dns_updater/cache/` (survives reboots).
- **Exclusion List**: Allows users to specify subdomains that should not be updated.

## Requirements
- `jq`: Used for JSON parsing.
- `curl`: Used for making API calls to Cloudflare, HTTP health checks, and sending notifications.
- `bc`: Used for response time comparison.
- Cloudflare API credentials: You need to have a valid Cloudflare email, API key, and zone ID.

## Configuration
Before running the script, you must configure it with your Cloudflare credentials and target domain information. This includes setting up a configuration file named `domain.json` in the following format:

```json
{
    "servers": {
        "vps-main": "192.168.1.1",
        "vps-backup": "192.168.1.2"
    },
    "defaults": {
        "primary_server": "vps-main",
        "secondary_server": "vps-backup"
    },
    "notifications": {
        "enabled": true,
        "events": ["failover", "failback", "both_offline"],
        "cooldown_minutes": 30,
        "channels": {
            "telegram": {
                "enabled": true,
                "bot_token": "123456:ABC-DEF...",
                "chat_id": "-1001234567890"
            },
            "slack": {
                "enabled": false,
                "webhook_url": "https://hooks.slack.com/services/T00/B00/xxx"
            },
            "webhook": {
                "enabled": false,
                "url": "https://your-endpoint.com/notify",
                "method": "POST"
            }
        }
    },
    "domains": [
        {
            "domain": "example.com",
            "email": "your-email@example.com",
            "api_key": "your-api-key",
            "zone_id": "your-zone-id",
            "excluded_subdomains": ["sub1", "sub2"],
            "response_timeout": 3,
            "max_retries": 3,
            "retry_delay": 2
        },
        {
            "domain": "example2.com",
            "primary_server": "vps-backup",
            "secondary_server": "vps-main",
            "email": "your-email@example.com",
            "api_key": "your-api-key",
            "zone_id": "your-zone-id-2",
            "excluded_subdomains": [],
            "notifications_enabled": false
        }
    ]
}
```

### Servers

Define each physical server once in the top-level `servers` map, then have
domains reference it by name. When a VPS is re-addressed you edit that one line
instead of hunting down every `primary_ip`/`secondary_ip` in the file.

`defaults` sets the primary and secondary server for every domain. A domain only
needs its own `primary_server`/`secondary_server` when it differs — for example
to swap the two roles, as `example2.com` does above.

| Field | Required | Description |
|-------|----------|-------------|
| `servers` | No | Map of server name to IPv4 address, e.g. `{"vps-main": "192.168.1.1"}` |
| `defaults.primary_server` | No | Server name used as primary by domains that do not set their own |
| `defaults.secondary_server` | No | Server name used as secondary by domains that do not set their own |

Each role is resolved in this order, first match wins:

1. the domain's `primary_server` / `secondary_server` (looked up in `servers`)
2. the domain's `primary_ip` / `secondary_ip` (legacy inline address)
3. `defaults.primary_server` / `defaults.secondary_server`
4. `defaults.primary_ip` / `defaults.secondary_ip`

A name that is not in the `servers` map is an error, never a silent fallback:
the domain is skipped, the run continues with the remaining domains, and the
reason is logged. Resolved addresses are validated as IPv4 before they reach the
Cloudflare API.

**Upgrading:** the older format, where every domain spells out `primary_ip` and
`secondary_ip`, still works exactly as before. You can deploy this version
without touching your config and migrate whenever it suits you.

### Domain Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `domain` | Yes | - | The domain name to monitor |
| `primary_server` | No\* | `defaults.primary_server` | Name of the primary server, defined in `servers` |
| `secondary_server` | No\* | `defaults.secondary_server` | Name of the failover server, defined in `servers` |
| `primary_ip` | No\* | - | Primary server IP address (legacy; prefer `primary_server`) |
| `secondary_ip` | No\* | - | Failover server IP address (legacy; prefer `secondary_server`) |
| `email` | Yes | - | Cloudflare account email |
| `api_key` | Yes | - | Cloudflare API key |
| `zone_id` | Yes | - | Cloudflare zone ID |
| `excluded_subdomains` | Yes | - | Subdomains to skip during updates |
| `response_timeout` | No | `3` | Max acceptable response time in seconds |
| `max_retries` | No | `3` | Number of retry attempts before declaring failure |
| `retry_delay` | No | `2` | Seconds to wait between retries |
| `notifications_enabled` | No | `true` | Set to `false` to disable notifications for this domain only |

\* Each role needs *one* source: a server name, a legacy inline IP, or a
matching entry under `defaults`. A domain with no primary at all is skipped.

### Notification Fields (global, all optional)

| Field | Default | Description |
|-------|---------|-------------|
| `notifications.enabled` | `false` | Master switch to enable/disable notifications for all domains |
| `notifications.events` | `["failover","failback","both_offline"]` | Which events trigger notifications |
| `notifications.cooldown_minutes` | `30` | Minimum minutes between repeated notifications of the same event type |
| `notifications.channels.telegram.enabled` | `false` | Enable Telegram notifications |
| `notifications.channels.telegram.bot_token` | - | Telegram Bot API token (from @BotFather) |
| `notifications.channels.telegram.chat_id` | - | Telegram chat/group ID |
| `notifications.channels.slack.enabled` | `false` | Enable Slack notifications |
| `notifications.channels.slack.webhook_url` | - | Slack Incoming Webhook URL |
| `notifications.channels.webhook.enabled` | `false` | Enable generic webhook notifications |
| `notifications.channels.webhook.url` | - | Webhook endpoint URL |
| `notifications.channels.webhook.method` | `POST` | HTTP method for the webhook |

### Setting up Telegram Notifications

1. Open Telegram and search for **@BotFather**
2. Send `/newbot` and follow the prompts to create a bot
3. Copy the bot token (format: `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)
4. Add your bot to a chat/group and send it a message
5. Get your chat ID:
   ```bash
   curl -s https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates | jq '.result[0].message.chat.id'
   ```
6. Add the `bot_token` and `chat_id` to your `domain.json`

## Usage

```bash
# Normal operation
./cloudflare_dns_updater.sh

# Simulate updates without making DNS changes
./cloudflare_dns_updater.sh --dry-run

# Use a custom config file
./cloudflare_dns_updater.sh --config /path/to/config.json

# Use a custom log file
./cloudflare_dns_updater.sh --log-file /path/to/logfile.log

# Show version
./cloudflare_dns_updater.sh --version

# Show help
./cloudflare_dns_updater.sh --help
```

The script will process each domain in the `domains` array. It checks if the domain is online and responding within the configured timeout, compares the current IP against the primary and secondary IPs, and updates the DNS records on Cloudflare if necessary. When a DNS change occurs, notifications are sent to all enabled channels (unless the domain has `notifications_enabled: false`).

## Logging

The script logs all operations with timestamps and severity levels to both the console (with colors) and a log file at `~/.cloudflare_dns_updater/dns_updater.log` (overridable via `--log-file`).

Log levels:
- **INFO** (blue): Normal operations (domain online, IP checks, updates, notifications sent).
- **WARN** (yellow): Retry attempts, slow responses, non-critical issues, notification suppressed by cooldown.
- **ERROR** (red): Failed health checks, API errors, update failures, notification failures.
- **CRITICAL** (bold red): Both IPs offline, urgent attention required.

## Customization

You can customize the script by modifying the `domain.json` file to include new domains or change IP addresses. The list of excluded subdomains can also be updated as per your requirements. Each domain can have its own `response_timeout`, `max_retries`, and `retry_delay`, or omit them to use the defaults. Notifications are configured globally and can be disabled per domain with `"notifications_enabled": false`.

## Automating Checks and Updates

To ensure that your DNS records are continuously monitored and updated without manual intervention, you can automate the execution of this script using cron on a Linux system. Here's how to set it up:

### Setting up a Cron Job

1. Open the crontab editor:

```bash
crontab -e
```

2. Add a cron job. For example, to run the script every 5 minutes:

```bash
*/5 * * * * /path/to/your/cloudflare_dns_updater.sh
```

Since the script already logs to `~/.cloudflare_dns_updater/dns_updater.log`, there is no need to redirect output manually. The notification cooldown prevents alert spam when running frequently via cron.

3. Save and exit the editor. The cron service will automatically pick up the new job and begin executing it at the specified interval.
