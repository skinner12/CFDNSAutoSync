# Cloudflare DNS Auto-Updater Architecture

## Overview

This document describes the architecture of the Cloudflare DNS Auto-Updater script, including system flow, failover logic, notification mechanisms, and configuration structure.

---

## 1. High-Level System Architecture

The system is triggered by a cron job at regular intervals. Each execution performs health checks on configured domains and IPs, then updates DNS records via the Cloudflare API when failover is needed. Notifications are sent through enabled channels while maintaining cooldown windows to prevent spam.

```mermaid
graph TD
    CRON["Cron Scheduler<br/>(e.g. every 5 min)"]
    SCRIPT["cloudflare_dns_updater.sh"]

    CRON -->|trigger| SCRIPT

    SCRIPT -->|1. Load| CONFIG["domain.json<br/>(global config + domains)"]
    SCRIPT -->|2. Check| DOMAIN_HEALTH["HTTP Health Check<br/>(curl https://domain)"]
    SCRIPT -->|3. Check| IP_HEALTH["IP Ping Check<br/>(ping IP address)"]

    DOMAIN_HEALTH -->|online/offline| LOGIC["Failover Decision Logic"]
    IP_HEALTH -->|online/offline| LOGIC

    LOGIC -->|read/write| CACHE["Cache Dir<br/>~/.cloudflare_dns_updater/cache<br/>(per-domain IP)"]

    LOGIC -->|needs update| CFE["Cloudflare API<br/>(update A records)"]
    CFE -->|success| DNS_UPDATE["DNS Records Updated"]

    LOGIC -->|event occurred| NOTIF["Notification Dispatcher"]

    NOTIF -->|check global config| NOTIF_CONFIG["Notifications Config<br/>(enabled, events, cooldown)"]
    NOTIF -->|check per-domain| DOMAIN_CONFIG["Domain Config<br/>(notifications_enabled)"]
    NOTIF -->|check cooldown| NOTIF_CACHE["Notification Cache<br/>~/.cloudflare_dns_updater/<br/>notification_cache"]

    NOTIF -->|if enabled| TELEGRAM["Telegram<br/>(send message)"]
    NOTIF -->|if enabled| SLACK["Slack Webhook<br/>(send message)"]
    NOTIF -->|if enabled| WEBHOOK["Custom Webhook<br/>(send JSON)"]

    SCRIPT -->|log all events| LOGS["Log File<br/>~/.cloudflare_dns_updater/<br/>dns_updater.log"]

    DNS_UPDATE --> LOGS
    TELEGRAM --> LOGS
    SLACK --> LOGS
    WEBHOOK --> LOGS
```

---

## 2. Failover Decision Flowchart

This is the core logic in `main()`. The script iterates through each configured domain and determines whether to update DNS records based on domain health, IP availability, and cached state.

```mermaid
graph TD
    START["Start Processing Domain"] --> GET_CACHE["Load Cached IP"]

    GET_CACHE --> CHECK_DOMAIN["Is Domain Online<br/>and Responsive?<br/>(HTTP 200 + resp time)"]

    CHECK_DOMAIN -->|NO - Domain Offline| FAILOVER["Failover Mode"]
    CHECK_DOMAIN -->|YES - Domain Online| ONLINE["Domain Online Path"]

    %% Domain Online Path
    ONLINE --> WAS_SECONDARY{{"Was on<br/>Secondary IP<br/>cached_ip == secondary_ip?"}}

    WAS_SECONDARY -->|YES| CHECK_PRIMARY_RECOVERY["Check if Primary<br/>IP Online<br/>(ping primary)"]

    CHECK_PRIMARY_RECOVERY -->|YES| DO_FAILBACK["Update DNS to Primary IP<br/>(failback)"]
    DO_FAILBACK --> SEND_FAILBACK["Send Failback<br/>Notification"]
    SEND_FAILBACK --> END1["✓ Complete"]

    CHECK_PRIMARY_RECOVERY -->|NO| KEEP_SECONDARY["Keep Secondary IP<br/>(no action)"]
    KEEP_SECONDARY --> END2["✓ Complete"]

    WAS_SECONDARY -->|NO| CACHED_NOT_PRIMARY{{"Cached IP != Primary IP"}}

    CACHED_NOT_PRIMARY -->|YES| CHECK_PRIMARY["Check if Primary IP Online<br/>(ping primary)"]

    CHECK_PRIMARY -->|YES| UPDATE_TO_PRIMARY["Update DNS to Primary IP<br/>(primary was down, now up)"]
    UPDATE_TO_PRIMARY --> END3["✓ Complete"]

    CHECK_PRIMARY -->|NO| CHECK_SECONDARY_ONLINE["Check if Secondary IP Online<br/>(ping secondary)"]

    CHECK_SECONDARY_ONLINE -->|YES| KEEP_SECONDARY2["Secondary is online<br/>Continue with secondary"]
    KEEP_SECONDARY2 --> END4["✓ Complete"]

    CHECK_SECONDARY_ONLINE -->|NO| CRITICAL_BOTH["CRITICAL: Both IPs Offline"]
    CRITICAL_BOTH --> SEND_CRITICAL["Send Critical Alert<br/>(both_offline)"]
    SEND_CRITICAL --> END5["✗ Complete"]

    CACHED_NOT_PRIMARY -->|NO| VALID["Primary IP is cached<br/>and valid"]
    VALID --> END6["✓ No action needed"]

    %% Failover Path
    FAILOVER --> CHECK_PRIMARY_FAILOVER["Check if Primary IP Online<br/>(ping primary)"]

    CHECK_PRIMARY_FAILOVER -->|YES| UPDATE_TO_PRIMARY_FAILOVER["Update DNS to Primary IP"]
    UPDATE_TO_PRIMARY_FAILOVER --> SEND_FAILOVER_PRIMARY["Send Failover Notification"]
    SEND_FAILOVER_PRIMARY --> END7["✓ Complete"]

    CHECK_PRIMARY_FAILOVER -->|NO| CHECK_SECONDARY_FAILOVER["Check if Secondary IP Online<br/>(ping secondary)"]

    CHECK_SECONDARY_FAILOVER -->|YES| UPDATE_TO_SECONDARY["Update DNS to Secondary IP"]
    UPDATE_TO_SECONDARY --> SEND_FAILOVER_SECONDARY["Send Failover Notification"]
    SEND_FAILOVER_SECONDARY --> END8["✓ Complete"]

    CHECK_SECONDARY_FAILOVER -->|NO| CRITICAL_FAILOVER["CRITICAL: Both IPs Offline"]
    CRITICAL_FAILOVER --> SEND_CRITICAL_FAILOVER["Send Critical Alert<br/>(both_offline)"]
    SEND_CRITICAL_FAILOVER --> END9["✗ Complete"]

    style START fill:#e1f5ff
    style END1 fill:#c8e6c9
    style END2 fill:#c8e6c9
    style END3 fill:#c8e6c9
    style END4 fill:#fff9c4
    style END5 fill:#ffccbc
    style END6 fill:#c8e6c9
    style END7 fill:#c8e6c9
    style END8 fill:#fff9c4
    style END9 fill:#ffccbc
    style CRITICAL_BOTH fill:#ff5252
    style CRITICAL_FAILOVER fill:#ff5252
    style DO_FAILBACK fill:#a5d6a7
    style UPDATE_TO_PRIMARY fill:#a5d6a7
    style UPDATE_TO_PRIMARY_FAILOVER fill:#a5d6a7
    style UPDATE_TO_SECONDARY fill:#fff59d
```

**Key Decision Points:**

- **Domain Online Check**: HTTP GET to domain (must return 200 with response under threshold)
- **Cached IP State**: Determines if we were previously on secondary, can attempt failback
- **IP Ping Check**: Verifies backend IP is reachable (primary/secondary)
- **Both Offline**: Critical alert sent, no DNS update occurs
- **Failback**: Automatic recovery when primary comes back online
- **Failover**: Automatic switch to secondary when domain is offline

---

## 3. Notification Flow

Notifications follow a multi-stage filtering pipeline: global enable check → per-domain opt-out → event type filter → cooldown check → channel fan-out. All channels are "fire and forget" to prevent blocking DNS updates.

```mermaid
graph TD
    TRIGGER["Notification Triggered<br/>(failover/failback/both_offline)"]

    TRIGGER --> GLOBAL_CHECK{{"Global Notifications<br/>Config Present<br/>and Enabled?"}}

    GLOBAL_CHECK -->|NO or disabled| DROP1["Drop: Notifications<br/>Globally Disabled"]
    DROP1 --> END_DROP1["Return"]

    GLOBAL_CHECK -->|YES| PER_DOMAIN_CHECK{{"Per-Domain Override<br/>notifications_enabled<br/>!= false?"}}

    PER_DOMAIN_CHECK -->|false| DROP2["Drop: Domain Opted Out"]
    DROP2 --> END_DROP2["Return"]

    PER_DOMAIN_CHECK -->|not false| EVENT_FILTER{{"Event Type in<br/>Config Events List?<br/>(default: failover,failback,<br/>both_offline)"}}

    EVENT_FILTER -->|NO| DROP3["Drop: Event Type<br/>Not Monitored"]
    DROP3 --> END_DROP3["Return"]

    EVENT_FILTER -->|YES| COOLDOWN_CHECK{{"Cooldown Passed?<br/>Check notification_cache<br/>for last send time"}}

    COOLDOWN_CHECK -->|NO| DROP4["Drop: In Cooldown<br/>Window"]
    DROP4 --> END_DROP4["Return"]

    COOLDOWN_CHECK -->|YES| UPDATE_CACHE["Update Cooldown Cache<br/>(record send time)"]

    UPDATE_CACHE --> GET_METADATA["Gather Event Metadata<br/>(timestamp, hostname,<br/>old_ip, new_ip, reason)"]

    GET_METADATA --> FANOUT["Fan Out to Channels<br/>(fire and forget)"]

    FANOUT --> TELEGRAM_ENABLED{{"Telegram<br/>Enabled?"}}
    TELEGRAM_ENABLED -->|YES| SEND_TG["Send Telegram<br/>Message<br/>(formatted with icon<br/>and rich text)"]
    TELEGRAM_ENABLED -->|NO| SKIP_TG["Skip Telegram"]

    SEND_TG --> TG_LOG["Log Result"]
    SKIP_TG --> TG_LOG

    FANOUT --> SLACK_ENABLED{{"Slack<br/>Enabled?"}}
    SLACK_ENABLED -->|YES| SEND_SLACK["Send Slack<br/>Webhook<br/>(formatted attachment<br/>with color code)"]
    SLACK_ENABLED -->|NO| SKIP_SLACK["Skip Slack"]

    SEND_SLACK --> SLACK_LOG["Log Result"]
    SKIP_SLACK --> SLACK_LOG

    FANOUT --> WEBHOOK_ENABLED{{"Webhook<br/>Enabled?"}}
    WEBHOOK_ENABLED -->|YES| SEND_WEBHOOK["Send Custom Webhook<br/>(JSON POST/custom method)"]
    WEBHOOK_ENABLED -->|NO| SKIP_WEBHOOK["Skip Webhook"]

    SEND_WEBHOOK --> WEBHOOK_LOG["Log Result"]
    SKIP_WEBHOOK --> WEBHOOK_LOG

    TG_LOG --> DONE["Return"]
    SLACK_LOG --> DONE
    WEBHOOK_LOG --> DONE

    style TRIGGER fill:#e1f5ff
    style DONE fill:#c8e6c9
    style END_DROP1 fill:#ffccbc
    style END_DROP2 fill:#ffccbc
    style END_DROP3 fill:#ffccbc
    style END_DROP4 fill:#fff9c4
    style FANOUT fill:#fff59d
    style SEND_TG fill:#c8e6c9
    style SEND_SLACK fill:#c8e6c9
    style SEND_WEBHOOK fill:#c8e6c9
```

**Notification Channels:**

- **Telegram**: Bot token + chat ID, sends formatted message with event icon
- **Slack**: Webhook URL, sends attachment with color-coded event type
- **Webhook**: Custom URL + optional method (POST/PUT), sends JSON payload

**Cooldown Behavior:**

- Per-domain, per-event-type cooldown (default 30 minutes)
- Prevents notification spam during repeated failovers
- Configurable per notification config
- Stored in `~/.cloudflare_dns_updater/notification_cache/`

---

## 4. Configuration Structure

The `domain.json` configuration file supports a new hierarchical structure with global notifications and per-domain settings, while maintaining backward compatibility with legacy array format.

```mermaid
graph TD
    CONFIG["domain.json<br/>(JSON)"]

    CONFIG --> GLOBAL["Global Settings<br/>(top-level)"]
    CONFIG --> DOMAINS["domains Array<br/>(array of domain configs)"]

    %% Global Notifications
    GLOBAL --> NOTIF["notifications<br/>(optional object)"]

    NOTIF --> NOTIF_ENABLED["enabled: boolean<br/>(default: false)"]
    NOTIF --> NOTIF_EVENTS["events: array<br/>(default: failover,failback,<br/>both_offline)"]
    NOTIF --> NOTIF_COOLDOWN["cooldown_minutes: number<br/>(default: 30)"]

    NOTIF --> CHANNELS["channels: object"]

    CHANNELS --> TG["telegram"]
    CHANNELS --> SLACK["slack"]
    CHANNELS --> WEBHOOK["webhook"]

    TG --> TG_ENABLED["enabled: boolean"]
    TG --> TG_BOT["bot_token: string"]
    TG --> TG_CHAT["chat_id: string"]

    SLACK --> SLACK_ENABLED["enabled: boolean"]
    SLACK --> SLACK_URL["webhook_url: string"]

    WEBHOOK --> WEBHOOK_ENABLED["enabled: boolean"]
    WEBHOOK --> WEBHOOK_URL["url: string"]
    WEBHOOK --> WEBHOOK_METHOD["method: string<br/>(POST, PUT, etc)"]

    %% Domain Configurations
    DOMAINS --> DOMAIN_OBJ["Domain 1, Domain 2, ...<br/>(each is an object)"]

    DOMAIN_OBJ --> DOMAIN_BASIC["domain: string<br/>(e.g. example.com)"]
    DOMAIN_OBJ --> PRIMARY["primary_ip: string<br/>(preferred backend IP)"]
    DOMAIN_OBJ --> SECONDARY["secondary_ip: string<br/>(failover IP)"]
    DOMAIN_OBJ --> CF_AUTH["email: string<br/>api_key: string<br/>zone_id: string<br/>(Cloudflare credentials)"]

    DOMAIN_OBJ --> DOMAIN_OPTS["Domain Options"]

    DOMAIN_OPTS --> EXCLUDED["excluded_subdomains: array<br/>(skip these in updates)"]
    DOMAIN_OPTS --> NOTIF_OVERRIDE["notifications_enabled: boolean<br/>(per-domain opt-out,<br/>default: true)"]
    DOMAIN_OPTS --> THRESHOLDS["response_timeout: number<br/>max_retries: number<br/>retry_delay: number<br/>(per-domain health check config)"]

    style CONFIG fill:#e1f5ff
    style GLOBAL fill:#f3e5f5
    style NOTIF fill:#f3e5f5
    style CHANNELS fill:#fff59d
    style TG fill:#c8e6c9
    style SLACK fill:#c8e6c9
    style WEBHOOK fill:#c8e6c9
    style DOMAINS fill:#ffe0b2
    style DOMAIN_OBJ fill:#ffe0b2
    style CF_AUTH fill:#ffccbc
    style DOMAIN_OPTS fill:#fff9c4
```

**Example Configuration:**

```json
{
  "notifications": {
    "enabled": true,
    "events": ["failover", "failback", "both_offline"],
    "cooldown_minutes": 30,
    "channels": {
      "telegram": {
        "enabled": true,
        "bot_token": "YOUR_BOT_TOKEN",
        "chat_id": "YOUR_CHAT_ID"
      },
      "slack": {
        "enabled": true,
        "webhook_url": "https://hooks.slack.com/services/..."
      },
      "webhook": {
        "enabled": false,
        "url": "https://your.api/webhook",
        "method": "POST"
      }
    }
  },
  "domains": [
    {
      "domain": "example.com",
      "primary_ip": "192.168.1.100",
      "secondary_ip": "192.168.1.101",
      "email": "user@cloudflare.com",
      "api_key": "YOUR_API_KEY",
      "zone_id": "ZONE_ID",
      "excluded_subdomains": ["internal", "dev"],
      "notifications_enabled": true,
      "response_timeout": 3,
      "max_retries": 3,
      "retry_delay": 2
    }
  ]
}
```

---

## File System Structure

```
~/.cloudflare_dns_updater/
├── cache/
│   ├── example.com          # Last known IP for example.com
│   └── another.com          # Last known IP for another.com
├── notification_cache/
│   ├── example.com_failover # Timestamp of last failover notification
│   └── example.com_failback # Timestamp of last failback notification
└── dns_updater.log          # Timestamped event log (INFO, WARN, ERROR, CRITICAL)
```

---

## Execution Flow Summary

1. **Cron Trigger**: Script runs at configured interval (e.g., every 5 minutes)
2. **Load Config**: Parse `domain.json` for global settings and domain list
3. **Iterate Domains**: For each domain, execute failover decision logic
4. **Health Checks**: HTTP check on domain, ping check on primary/secondary IPs
5. **Cache Lookup**: Compare current cached IP with newly determined IP
6. **Failover Decision**: Update DNS if state changed (see flowchart section 2)
7. **API Call**: If update needed, call Cloudflare API to update all A records
8. **Notification**: If event occurred, dispatch notifications through enabled channels
9. **Logging**: Record all actions to persistent log file
10. **Exit**: Return exit code 0 for success, 1 for errors

---

## Error Handling

- **Network Errors**: Retried with configurable delays and max attempts
- **API Errors**: Logged with error message from Cloudflare
- **Missing Config**: Script exits with error
- **Offline Domains**: Failover attempted automatically
- **Both IPs Down**: Critical alert sent, no DNS change (prevents misconfiguration)
- **Notification Failures**: Logged but do not block DNS updates (fire-and-forget)

---

## Performance Considerations

- **Health Checks**: Default 3-second timeout per request with up to 3 retries
- **Notification Cooldown**: Prevents duplicate alerts (default 30 minutes)
- **Non-Blocking**: Failed notifications do not interrupt DNS updates
- **Concurrent Domains**: Each domain processed sequentially in a single script run
- **Cache**: Persistent cache avoids redundant updates when state hasn't changed

