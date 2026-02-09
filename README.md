# Cloudflare DNS Update Script

## Overview
This script is designed to automate the process of updating DNS records on Cloudflare for specified domains. It checks the online status and response time of the domain, verifies IP consistency, and updates DNS records if necessary. It handles primary and secondary IP failovers with automatic failback, and excludes certain subdomains from updates based on a predefined list.

## Features
- **Response Time Detection**: Fails over if the server responds too slowly (configurable threshold, default 3s), not just when it's completely offline.
- **Retry Logic**: Retries health checks multiple times before declaring failure, avoiding false positives from transient network issues.
- **Auto Failback**: Automatically switches back to the primary IP when it recovers, even while the domain is still online on the secondary IP.
- **Failover Handling**: Switches to a secondary IP if the primary IP is offline or too slow.
- **DNS Record Validation**: Checks current DNS record content before updating, skipping records already at the target IP.
- **Dry-Run Mode**: Simulate updates without making actual DNS changes using `--dry-run`.
- **Timestamped Logging**: All operations are logged with timestamps and severity levels (INFO/WARN/ERROR/CRITICAL) to both console and log file.
- **Per-Domain Configuration**: Each domain can have its own response timeout, retry count, and retry delay.
- **Persistent Cache**: IP cache stored in `~/.cloudflare_dns_updater/cache/` (survives reboots).
- **Exclusion List**: Allows users to specify subdomains that should not be updated.

## Requirements
- `jq`: Used for JSON parsing.
- `curl`: Used for making API calls to Cloudflare and HTTP health checks.
- `bc`: Used for response time comparison.
- Cloudflare API credentials: You need to have a valid Cloudflare email, API key, and zone ID.

## Configuration
Before running the script, you must configure it with your Cloudflare credentials and target domain information. This includes setting up a configuration file named `domain.json` in the following format:

```json
[
    {
        "domain": "example.com",
        "primary_ip": "192.168.1.1",
        "secondary_ip": "192.168.1.2",
        "email": "your-email@example.com",
        "api_key": "your-api-key",
        "zone_id": "your-zone-id",
        "excluded_subdomains": ["sub1", "sub2"],
        "response_timeout": 3,
        "max_retries": 3,
        "retry_delay": 2
    }
]
```

### Configuration Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `domain` | Yes | - | The domain name to monitor |
| `primary_ip` | Yes | - | Primary server IP address |
| `secondary_ip` | Yes | - | Failover server IP address |
| `email` | Yes | - | Cloudflare account email |
| `api_key` | Yes | - | Cloudflare API key |
| `zone_id` | Yes | - | Cloudflare zone ID |
| `excluded_subdomains` | Yes | - | Subdomains to skip during updates |
| `response_timeout` | No | `3` | Max acceptable response time in seconds |
| `max_retries` | No | `3` | Number of retry attempts before declaring failure |
| `retry_delay` | No | `2` | Seconds to wait between retries |

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

# Show help
./cloudflare_dns_updater.sh --help
```

The script will process each domain defined in your `domain.json` file. It will check if the domain is online and responding within the configured timeout, compare the current IP against the primary and secondary IPs, and update the DNS records on Cloudflare if necessary.

## Logging

The script logs all operations with timestamps and severity levels to both the console (with colors) and a log file at `~/.cloudflare_dns_updater/dns_updater.log` (overridable via `--log-file`).

Log levels:
- **INFO** (blue): Normal operations (domain online, IP checks, updates).
- **WARN** (yellow): Retry attempts, slow responses, non-critical issues.
- **ERROR** (red): Failed health checks, API errors, update failures.
- **CRITICAL** (bold red): Both IPs offline, urgent attention required.

## Customization

You can customize the script by modifying the `domain.json` file to include new domains or change IP addresses. The list of excluded subdomains can also be updated as per your requirements. Each domain can have its own `response_timeout`, `max_retries`, and `retry_delay` values, or omit them to use the defaults.

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

Since the script already logs to `~/.cloudflare_dns_updater/dns_updater.log`, there is no need to redirect output manually.

3. Save and exit the editor. The cron service will automatically pick up the new job and begin executing it at the specified interval.
