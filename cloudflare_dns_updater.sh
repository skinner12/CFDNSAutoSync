#!/bin/bash

# Configuration defaults
CONFIG_FILE="domain.json"
CLOUDFLARE_API_ENDPOINT="https://api.cloudflare.com/client/v4"
CACHE_DIR="${HOME}/.cloudflare_dns_updater/cache"
LOG_FILE="${HOME}/.cloudflare_dns_updater/dns_updater.log"
DRY_RUN=false
DEFAULT_RESPONSE_TIMEOUT=3
DEFAULT_MAX_RETRIES=3
DEFAULT_RETRY_DELAY=2

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

# Check if an IP is reachable by pinging it
check_ip_online() {
    local ip=$1
    local max_retries=${2:-$DEFAULT_MAX_RETRIES}
    local retry_delay=${3:-$DEFAULT_RETRY_DELAY}
    local attempt

    for ((attempt = 1; attempt <= max_retries; attempt++)); do
        if ping -c 3 -W 2 "$ip" >/dev/null 2>&1; then
            log_message "INFO" "IP $ip is online"
            return 0
        fi

        log_message "WARN" "Attempt $attempt/$max_retries: IP $ip is unreachable"
        if [[ $attempt -lt $max_retries ]]; then
            sleep "$retry_delay"
        fi
    done

    log_message "ERROR" "IP $ip is offline after $max_retries attempts"
    return 1
}

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
        if [[ " ${excluded_subdomains[*]} " =~ " $subdomain_part " ]]; then
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

        # BUG FIX: validate update_response, not records_json
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

# Main function to iterate through configurations
main() {
    local domain primary_ip secondary_ip email api_key zone_id excluded_subdomains
    local cache_file cached_ip config response_timeout max_retries retry_delay

    mkdir -p "$CACHE_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"

    log_message "INFO" "=== DNS updater started ==="
    if [[ "$DRY_RUN" == "true" ]]; then
        log_message "WARN" "Running in DRY-RUN mode - no DNS changes will be made"
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_message "ERROR" "Config file not found: $CONFIG_FILE"
        return 1
    fi

    configs=$(jq -c '.[]' <"$CONFIG_FILE" 2>/dev/null)
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

            # BUG FIX: auto failback - if on secondary, check if primary recovered
            if [[ "$cached_ip" == "$secondary_ip" ]]; then
                if check_ip_online "$primary_ip" "$max_retries" "$retry_delay"; then
                    log_message "INFO" "Primary IP $primary_ip recovered. Failing back from secondary $secondary_ip..."
                    update_cloudflare_dns "$email" "$api_key" "$zone_id" "$domain" "$primary_ip" "${excluded_subdomains[@]}"
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
            elif check_ip_online "$secondary_ip" "$max_retries" "$retry_delay"; then
                update_cloudflare_dns "$email" "$api_key" "$zone_id" "$domain" "$secondary_ip" "${excluded_subdomains[@]}"
                log_message "INFO" "Switched to secondary IP $secondary_ip for $domain"
            else
                log_message "CRITICAL" "Both IPs offline for $domain. Urgent attention required!"
            fi
        fi
    done

    log_message "INFO" "=== DNS updater finished ==="
}

# Parse command-line arguments
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
            --help)
                printf "Usage: %s [OPTIONS]\n\n" "$0"
                printf "Options:\n"
                printf "  --dry-run          Simulate updates without making DNS changes\n"
                printf "  --config FILE      Config file path (default: domain.json)\n"
                printf "  --log-file FILE    Log file path (default: ~/.cloudflare_dns_updater/dns_updater.log)\n"
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
main
