#!/bin/bash

VERSION="1.1.2"

# Configuration defaults
CONFIG_FILE="domain.json"
CLOUDFLARE_API_ENDPOINT="https://api.cloudflare.com/client/v4"
LOCK_FILE="${HOME}/.cloudflare_dns_updater/dns_updater.lock"
CACHE_DIR="${HOME}/.cloudflare_dns_updater/cache"
NOTIFICATION_CACHE_DIR="${HOME}/.cloudflare_dns_updater/notification_cache"
LOG_FILE="${HOME}/.cloudflare_dns_updater/dns_updater.log"
DRY_RUN=false
DEFAULT_RESPONSE_TIMEOUT=3
DEFAULT_MAX_RETRIES=3
DEFAULT_RETRY_DELAY=2
DEFAULT_NOTIFICATION_COOLDOWN=30

# Ensure dependencies are installed
for cmd in jq curl bc; do
    if ! command -v "$cmd" &>/dev/null; then
        printf "%s is not installed. Please install %s to run this script.\n" "$cmd" "$cmd" >&2
        exit 1
    fi
done

# Logging function with timestamp and level
log_message() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local entry="[$timestamp] [$level] $message"

    # Write to log file
    echo "$entry" >> "$LOG_FILE"

    # Print to console with color
    case "$level" in
        INFO)     echo -e "\033[34m$entry\033[0m" ;;
        WARN)     echo -e "\033[33m$entry\033[0m" ;;
        ERROR)    echo -e "\033[31m$entry\033[0m" ;;
        CRITICAL) echo -e "\033[31m\033[1m$entry\033[0m" ;;
        *)        echo "$entry" ;;
    esac
}

# ─── Notification Functions ───────────────────────────────────

# Check cooldown to avoid notification spam
should_send_notification() {
    local domain=$1
    local event_type=$2
    local cooldown_minutes=${3:-$DEFAULT_NOTIFICATION_COOLDOWN}

    local cache_file="$NOTIFICATION_CACHE_DIR/${domain}_${event_type}"

    if [[ -f "$cache_file" ]]; then
        local last_sent now diff
        last_sent=$(cat "$cache_file")
        now=$(date +%s)
        diff=$(( (now - last_sent) / 60 ))
        if [[ $diff -lt $cooldown_minutes ]]; then
            log_message "INFO" "Notification suppressed: $event_type for $domain (sent ${diff}m ago, cooldown: ${cooldown_minutes}m)"
            return 1
        fi
    fi

    mkdir -p "$NOTIFICATION_CACHE_DIR"
    date +%s > "$cache_file"
    return 0
}

# Send Telegram notification
send_telegram() {
    local config=$1 event_type=$2 domain=$3 old_ip=$4 new_ip=$5 reason=$6 timestamp=$7 hostname=$8

    local bot_token chat_id
    bot_token=$(echo "$config" | jq -r '.channels.telegram.bot_token')
    chat_id=$(echo "$config" | jq -r '.channels.telegram.chat_id')

    if [[ -z "$bot_token" ]] || [[ -z "$chat_id" ]] || [[ "$bot_token" == "null" ]] || [[ "$chat_id" == "null" ]]; then
        log_message "WARN" "Telegram notification skipped: missing bot_token or chat_id for $domain"
        return 1
    fi

    local icon subject
    case "$event_type" in
        failover)     icon="🔴"; subject="DNS FAILOVER" ;;
        failback)     icon="🟢"; subject="DNS FAILBACK" ;;
        both_offline) icon="🚨"; subject="CRITICAL: ALL IPs OFFLINE" ;;
        *)            icon="🔄"; subject="DNS UPDATE" ;;
    esac

    local text
    text="${icon} <b>${subject}</b>

<b>Domain:</b> ${domain}
<b>Old IP:</b> <code>${old_ip}</code>
<b>New IP:</b> <code>${new_ip}</code>
<b>Reason:</b> ${reason}
<b>Time:</b> ${timestamp}
<b>Host:</b> ${hostname}"

    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 -X POST \
        "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "parse_mode=HTML" \
        -d "text=${text}" 2>/dev/null)

    if [[ "$(echo "$response" | jq -r '.ok // false')" != "true" ]]; then
        log_message "ERROR" "Telegram notification failed for $domain: $(echo "$response" | jq -r '.description // "unknown error"')"
        return 1
    fi
    log_message "INFO" "Telegram notification sent for $domain ($event_type)"
}

# Send Slack notification
send_slack() {
    local config=$1 event_type=$2 domain=$3 old_ip=$4 new_ip=$5 reason=$6 timestamp=$7 hostname=$8

    local webhook_url
    webhook_url=$(echo "$config" | jq -r '.channels.slack.webhook_url')

    if [[ -z "$webhook_url" ]] || [[ "$webhook_url" == "null" ]]; then
        log_message "WARN" "Slack notification skipped: missing webhook_url for $domain"
        return 1
    fi

    local color
    case "$event_type" in
        failover)     color="#dc3545" ;;
        failback)     color="#28a745" ;;
        both_offline) color="#ff0000" ;;
        *)            color="#007bff" ;;
    esac

    local payload
    payload=$(jq -n \
        --arg color "$color" \
        --arg event "$event_type" \
        --arg domain "$domain" \
        --arg old_ip "$old_ip" \
        --arg new_ip "$new_ip" \
        --arg reason "$reason" \
        --arg ts "$timestamp" \
        --arg host "$hostname" \
        '{attachments: [{
            color: $color,
            title: ("DNS " + ($event | ascii_upcase)),
            fields: [
                {title: "Domain", value: $domain, short: true},
                {title: "Old IP", value: $old_ip, short: true},
                {title: "New IP", value: $new_ip, short: true},
                {title: "Reason", value: $reason, short: false},
                {title: "Time", value: $ts, short: true},
                {title: "Host", value: $host, short: true}
            ]
        }]}')

    local http_code
    http_code=$(curl -s -o /dev/null --connect-timeout 5 --max-time 10 \
        -w "%{http_code}" -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    if [[ "$http_code" -ne 200 ]]; then
        log_message "ERROR" "Slack notification failed for $domain (HTTP $http_code)"
        return 1
    fi
    log_message "INFO" "Slack notification sent for $domain ($event_type)"
}

# Send generic webhook notification
send_webhook() {
    local config=$1 event_type=$2 domain=$3 old_ip=$4 new_ip=$5 reason=$6 timestamp=$7 hostname=$8

    local url method
    url=$(echo "$config" | jq -r '.channels.webhook.url')
    method=$(echo "$config" | jq -r '.channels.webhook.method // "POST"')

    if [[ -z "$url" ]] || [[ "$url" == "null" ]]; then
        log_message "WARN" "Webhook notification skipped: missing url for $domain"
        return 1
    fi

    local payload
    payload=$(jq -n \
        --arg event "$event_type" \
        --arg domain "$domain" \
        --arg old_ip "$old_ip" \
        --arg new_ip "$new_ip" \
        --arg reason "$reason" \
        --arg ts "$timestamp" \
        --arg host "$hostname" \
        '{event: $event, domain: $domain, old_ip: $old_ip, new_ip: $new_ip,
          reason: $reason, timestamp: $ts, hostname: $host}')

    local http_code
    http_code=$(curl -s -o /dev/null --connect-timeout 5 --max-time 10 \
        -w "%{http_code}" -X "$method" "$url" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    if [[ "$http_code" -lt 200 ]] || [[ "$http_code" -ge 300 ]]; then
        log_message "ERROR" "Webhook notification failed for $domain (HTTP $http_code)"
        return 1
    fi
    log_message "INFO" "Webhook notification sent for $domain ($event_type)"
}

# Notification dispatcher: checks global config, per-domain override, cooldown, then fans out
send_notification() {
    local notif_config=$1
    local domain_notif_enabled=$2
    local event_type=$3
    local domain=$4
    local old_ip=$5
    local new_ip=$6
    local reason=$7

    # Check if notifications are globally enabled
    if [[ -z "$notif_config" ]] || [[ "$notif_config" == "null" ]]; then
        return 0
    fi
    local notif_enabled
    notif_enabled=$(echo "$notif_config" | jq -r '.enabled // false')
    if [[ "$notif_enabled" != "true" ]]; then
        return 0
    fi

    # Per-domain override: domain can opt out with "notifications_enabled": false
    if [[ "$domain_notif_enabled" == "false" ]]; then
        return 0
    fi

    # Check if this event type is in the configured events list
    local event_match
    event_match=$(echo "$notif_config" | jq -r \
        --arg evt "$event_type" \
        '.events // ["failover","failback","both_offline"] | index($evt) // empty')
    if [[ -z "$event_match" ]]; then
        return 0
    fi

    # Check cooldown
    local cooldown_minutes
    cooldown_minutes=$(echo "$notif_config" | jq -r '.cooldown_minutes // empty')
    cooldown_minutes=${cooldown_minutes:-$DEFAULT_NOTIFICATION_COOLDOWN}
    if ! should_send_notification "$domain" "$event_type" "$cooldown_minutes"; then
        return 0
    fi

    local timestamp hostname
    timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    hostname=$(hostname -s 2>/dev/null || echo "unknown")

    # Fan out to enabled channels (fire-and-forget, never block DNS updates)
    if [[ "$(echo "$notif_config" | jq -r '.channels.telegram.enabled // false')" == "true" ]]; then
        send_telegram "$notif_config" "$event_type" "$domain" "$old_ip" "$new_ip" "$reason" "$timestamp" "$hostname"
    fi

    if [[ "$(echo "$notif_config" | jq -r '.channels.slack.enabled // false')" == "true" ]]; then
        send_slack "$notif_config" "$event_type" "$domain" "$old_ip" "$new_ip" "$reason" "$timestamp" "$hostname"
    fi

    if [[ "$(echo "$notif_config" | jq -r '.channels.webhook.enabled // false')" == "true" ]]; then
        send_webhook "$notif_config" "$event_type" "$domain" "$old_ip" "$new_ip" "$reason" "$timestamp" "$hostname"
    fi
}

# ─── Health Check Functions ───────────────────────────────────

# Check if a domain is online and responding fast enough
check_domain_online() {
    local domain=$1
    local response_timeout=${2:-$DEFAULT_RESPONSE_TIMEOUT}
    local max_retries=${3:-$DEFAULT_MAX_RETRIES}
    local retry_delay=${4:-$DEFAULT_RETRY_DELAY}
    local attempt

    for ((attempt = 1; attempt <= max_retries; attempt++)); do
        local http_output status_code response_time

        # Single curl call capturing both status code and response time
        http_output=$(curl -o /dev/null -s -L \
            -w "%{http_code} %{time_total}" \
            --connect-timeout 10 \
            --max-time "$((response_timeout + 5))" \
            "https://$domain" 2>/dev/null)

        status_code=$(echo "$http_output" | awk '{print $1}')
        response_time=$(echo "$http_output" | awk '{print $2}')

        # Handle failed curl (empty output)
        if [[ -z "$status_code" ]] || [[ -z "$response_time" ]]; then
            log_message "WARN" "Attempt $attempt/$max_retries: Failed to connect to $domain"
            if [[ $attempt -lt $max_retries ]]; then
                sleep "$retry_delay"
            fi
            continue
        fi

        # Check response time threshold
        if (( $(echo "$response_time > $response_timeout" | bc -l) )); then
            log_message "WARN" "Attempt $attempt/$max_retries: $domain responded in ${response_time}s (threshold: ${response_timeout}s)"
            if [[ $attempt -lt $max_retries ]]; then
                sleep "$retry_delay"
                continue
            fi
            log_message "ERROR" "$domain too slow after $max_retries attempts"
            return 1
        fi

        # Check HTTP status
        if [[ "$status_code" -eq 200 ]]; then
            log_message "INFO" "$domain is online (HTTP 200, ${response_time}s)"
            return 0
        fi

        log_message "WARN" "Attempt $attempt/$max_retries: $domain returned HTTP $status_code (${response_time}s)"
        if [[ $attempt -lt $max_retries ]]; then
            sleep "$retry_delay"
        fi
    done

    log_message "ERROR" "$domain offline/unhealthy after $max_retries attempts"
    return 1
}

# Check if an IP is reachable by ping and has web service running (port 80/443)
check_ip_online() {
    local ip=$1
    local max_retries=${2:-$DEFAULT_MAX_RETRIES}
    local retry_delay=${3:-$DEFAULT_RETRY_DELAY}
    local attempt

    for ((attempt = 1; attempt <= max_retries; attempt++)); do
        # Check ICMP ping
        if ! ping -c 2 -W 2 "$ip" >/dev/null 2>&1; then
            log_message "WARN" "Attempt $attempt/$max_retries: IP $ip is unreachable (ping failed)"
            if [[ $attempt -lt $max_retries ]]; then
                sleep "$retry_delay"
            fi
            continue
        fi

        # Check TCP port 443 (HTTPS), fallback to port 80 (HTTP)
        if curl -s --connect-timeout 3 --max-time 5 -o /dev/null "https://$ip" -k 2>/dev/null ||
           curl -s --connect-timeout 3 --max-time 5 -o /dev/null "http://$ip" 2>/dev/null; then
            log_message "INFO" "IP $ip is online (ping + port check OK)"
            return 0
        fi

        log_message "WARN" "Attempt $attempt/$max_retries: IP $ip responds to ping but web service is down (port 80/443 closed)"
        if [[ $attempt -lt $max_retries ]]; then
            sleep "$retry_delay"
        fi
    done

    log_message "ERROR" "IP $ip is offline after $max_retries attempts"
    return 1
}

# ─── DNS Update Function ─────────────────────────────────────

# Update Cloudflare DNS A records for all subdomains except excluded ones
update_cloudflare_dns() {
    local email=$1
    local api_key=$2
    local zone_id=$3
    local domain=$4
    local new_ip=$5
    local excluded_subdomains=("${@:6}")

    # Fetch all DNS records
    local records_json
    if ! records_json=$(curl -s -X GET "$CLOUDFLARE_API_ENDPOINT/zones/$zone_id/dns_records?type=A" \
            -H "X-Auth-Email: $email" \
            -H "X-Auth-Key: $api_key" \
            -H "Content-Type: application/json"); then
        log_message "ERROR" "Failed to fetch DNS records for $domain: network/curl error"
        return 1
    fi

    if [ -z "$records_json" ] || [[ "$records_json" == *'"result":[]'* ]]; then
        log_message "ERROR" "No DNS records found for $domain"
        return 1
    fi

    local success errors
    success=$(echo "$records_json" | jq -r '.success')
    errors=$(echo "$records_json" | jq -r '.errors | length')
    if [[ "$success" != "true" ]] || [[ "$errors" -gt 0 ]]; then
        log_message "ERROR" "Failed to fetch DNS records for $domain: $(echo "$records_json" | jq -r '.errors')"
        return 1
    fi

    local records_count record_name record_id current_ip
    records_count=$(echo "$records_json" | jq '.result | length')
    for ((i = 0; i < records_count; i++)); do
        record_name=$(echo "$records_json" | jq -r ".result[$i].name")
        record_id=$(echo "$records_json" | jq -r ".result[$i].id")
        current_ip=$(echo "$records_json" | jq -r ".result[$i].content")
        subdomain_part="${record_name%."$domain"}"

        # Skip excluded subdomains
        if [[ " ${excluded_subdomains[*]} " =~ [[:space:]]${subdomain_part}[[:space:]] ]]; then
            log_message "INFO" "Skipped $record_name (excluded)"
            continue
        fi

        # Skip if DNS record already has the target IP
        if [[ "$current_ip" == "$new_ip" ]]; then
            log_message "INFO" "Skipped $record_name (already set to $new_ip)"
            continue
        fi

        # Dry-run mode: log what would happen without making changes
        if [[ "$DRY_RUN" == "true" ]]; then
            log_message "INFO" "[DRY-RUN] Would update $record_name from $current_ip to $new_ip"
            continue
        fi

        local update_response
        if ! update_response=$(curl -s -X PUT "$CLOUDFLARE_API_ENDPOINT/zones/$zone_id/dns_records/$record_id" \
                -H "X-Auth-Email: $email" \
                -H "X-Auth-Key: $api_key" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"A\",\"name\":\"$record_name\",\"content\":\"$new_ip\",\"ttl\":1,\"proxied\":true}"); then
            log_message "ERROR" "Failed to update $record_name: network/curl error"
            return 1
        fi

        local update_success update_errors
        update_success=$(echo "$update_response" | jq -r '.success')
        update_errors=$(echo "$update_response" | jq -r '.errors | length')
        if [[ "$update_success" != "true" ]] || [[ "$update_errors" -gt 0 ]]; then
            log_message "ERROR" "Failed to update $record_name: $(echo "$update_response" | jq -r '.errors')"
            return 1
        fi

        log_message "INFO" "Updated $record_name from $current_ip to $new_ip"
    done

    # Write cache at domain level after all records are updated successfully
    echo "$new_ip" > "$CACHE_DIR/$domain"
}

# ─── Main Function ────────────────────────────────────────────

main() {
    local domain primary_ip secondary_ip email api_key zone_id excluded_subdomains
    local cache_file cached_ip config response_timeout max_retries retry_delay
    local notif_config domain_notif_enabled

    mkdir -p "$CACHE_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"

    log_message "INFO" "=== DNS updater v${VERSION} started ==="
    if [[ "$DRY_RUN" == "true" ]]; then
        log_message "WARN" "Running in DRY-RUN mode - no DNS changes will be made"
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_message "ERROR" "Config file not found: $CONFIG_FILE"
        return 1
    fi

    # Read global notification config (top-level "notifications" key)
    notif_config=$(jq -c '.notifications // empty' <"$CONFIG_FILE" 2>/dev/null)

    # Read domains array (supports both new object format and legacy array format)
    local configs
    if jq -e '.domains' <"$CONFIG_FILE" >/dev/null 2>&1; then
        configs=$(jq -c '.domains[]' <"$CONFIG_FILE" 2>/dev/null)
    else
        configs=$(jq -c '.[]' <"$CONFIG_FILE" 2>/dev/null)
    fi

    if [[ -z "$configs" ]]; then
        log_message "ERROR" "Failed to parse config file or no domains configured: $CONFIG_FILE"
        return 1
    fi

    echo "$configs" | while IFS= read -r config; do
        domain=$(echo "$config" | jq -r '.domain')
        primary_ip=$(echo "$config" | jq -r '.primary_ip')
        secondary_ip=$(echo "$config" | jq -r '.secondary_ip')
        email=$(echo "$config" | jq -r '.email')
        api_key=$(echo "$config" | jq -r '.api_key')
        zone_id=$(echo "$config" | jq -r '.zone_id')
        mapfile -t excluded_subdomains < <(echo "$config" | jq -r '.excluded_subdomains[]' 2>/dev/null)

        # Per-domain notification override (default: enabled unless explicitly false)
        domain_notif_enabled=$(echo "$config" | jq -r '.notifications_enabled // "true"')

        # Per-domain configurable thresholds (fall back to defaults)
        response_timeout=$(echo "$config" | jq -r '.response_timeout // empty')
        response_timeout=${response_timeout:-$DEFAULT_RESPONSE_TIMEOUT}
        max_retries=$(echo "$config" | jq -r '.max_retries // empty')
        max_retries=${max_retries:-$DEFAULT_MAX_RETRIES}
        retry_delay=$(echo "$config" | jq -r '.retry_delay // empty')
        retry_delay=${retry_delay:-$DEFAULT_RETRY_DELAY}

        cache_file="$CACHE_DIR/$domain"
        cached_ip=$(cat "$cache_file" 2>/dev/null || echo "")

        log_message "INFO" "Processing domain: $domain (timeout: ${response_timeout}s, retries: $max_retries)"

        # Check if domain is online and responsive
        if check_domain_online "$domain" "$response_timeout" "$max_retries" "$retry_delay"; then
            log_message "INFO" "$domain is online. Checking IP consistency..."

            # Auto failback - if on secondary, check if primary recovered
            if [[ "$cached_ip" == "$secondary_ip" ]]; then
                if check_ip_online "$primary_ip" "$max_retries" "$retry_delay"; then
                    log_message "INFO" "Primary IP $primary_ip recovered. Failing back from secondary $secondary_ip..."
                    update_cloudflare_dns "$email" "$api_key" "$zone_id" "$domain" "$primary_ip" "${excluded_subdomains[@]}"
                    send_notification "$notif_config" "$domain_notif_enabled" "failback" "$domain" "$secondary_ip" "$primary_ip" "Primary IP recovered"
                else
                    log_message "INFO" "Primary still down. Continuing on secondary IP $secondary_ip for $domain"
                fi
            elif [[ "$cached_ip" != "$primary_ip" ]]; then
                if check_ip_online "$primary_ip" "$max_retries" "$retry_delay"; then
                    log_message "INFO" "Primary IP $primary_ip is online, cached IP is $cached_ip. Updating DNS..."
                    update_cloudflare_dns "$email" "$api_key" "$zone_id" "$domain" "$primary_ip" "${excluded_subdomains[@]}"
                else
                    log_message "WARN" "Primary IP $primary_ip is offline. Checking secondary..."
                    if check_ip_online "$secondary_ip" "$max_retries" "$retry_delay"; then
                        log_message "INFO" "Continuing to use secondary IP $secondary_ip for $domain"
                    else
                        log_message "CRITICAL" "Both IPs offline for $domain. Urgent attention required!"
                        send_notification "$notif_config" "$domain_notif_enabled" "both_offline" "$domain" "$primary_ip" "$secondary_ip" "Both primary and secondary IPs unreachable"
                    fi
                fi
            else
                log_message "INFO" "IP $primary_ip for $domain is valid and online. No action needed."
            fi
        else
            log_message "ERROR" "$domain is offline or too slow. Initiating failover..."
            if check_ip_online "$primary_ip" "$max_retries" "$retry_delay"; then
                update_cloudflare_dns "$email" "$api_key" "$zone_id" "$domain" "$primary_ip" "${excluded_subdomains[@]}"
                log_message "INFO" "Switched to primary IP $primary_ip for $domain"
                send_notification "$notif_config" "$domain_notif_enabled" "failover" "$domain" "$cached_ip" "$primary_ip" "Domain offline or too slow, switched to primary"
            elif check_ip_online "$secondary_ip" "$max_retries" "$retry_delay"; then
                update_cloudflare_dns "$email" "$api_key" "$zone_id" "$domain" "$secondary_ip" "${excluded_subdomains[@]}"
                log_message "INFO" "Switched to secondary IP $secondary_ip for $domain"
                send_notification "$notif_config" "$domain_notif_enabled" "failover" "$domain" "$cached_ip" "$secondary_ip" "Domain offline or too slow, failover to secondary"
            else
                log_message "CRITICAL" "Both IPs offline for $domain. Urgent attention required!"
                send_notification "$notif_config" "$domain_notif_enabled" "both_offline" "$domain" "$primary_ip" "$secondary_ip" "Both primary and secondary IPs unreachable"
            fi
        fi
    done

    log_message "INFO" "=== DNS updater v${VERSION} finished ==="
}

# ─── CLI Argument Parsing ─────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            --version)
                printf "cloudflare_dns_updater v%s\n" "$VERSION"
                exit 0
                ;;
            --help)
                printf "cloudflare_dns_updater v%s\n\n" "$VERSION"
                printf "Usage: %s [OPTIONS]\n\n" "$0"
                printf "Options:\n"
                printf "  --dry-run          Simulate updates without making DNS changes\n"
                printf "  --config FILE      Config file path (default: domain.json)\n"
                printf "  --log-file FILE    Log file path (default: ~/.cloudflare_dns_updater/dns_updater.log)\n"
                printf "  --version          Show version number\n"
                printf "  --help             Show this help message\n"
                exit 0
                ;;
            *)
                printf "Unknown option: %s\nUse --help for usage information.\n" "$1" >&2
                exit 1
                ;;
        esac
    done
}

parse_args "$@"

# Lock file to prevent overlapping runs
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE")
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "Another instance is already running (PID $LOCK_PID). Skipping."
        exit 0
    fi
    # Stale lock file (process no longer running), remove it
    rm -f "$LOCK_FILE"
fi

mkdir -p "$(dirname "$LOCK_FILE")"
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

main
