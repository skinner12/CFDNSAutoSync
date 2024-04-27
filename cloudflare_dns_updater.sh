#!/bin/bash

# Configuration file path
CONFIG_FILE="domain.json"
CLOUDFLARE_API_ENDPOINT="https://api.cloudflare.com/client/v4"
IP_CACHE_DIR="/tmp/ip_cache_directory" # Using /tmp for cache storage

# Ensure jq is installed
if ! command -v jq &>/dev/null; then
    printf "jq is not installed. Please install jq to run this script.\n" >&2
    exit 1
fi

# Function to check if a domain is online by making an HTTP request
check_domain_online() {
    local status_code
    local domain=$1
    status_code=$(curl -o /dev/null -s -L -w "%{http_code}\n" --connect-timeout 10 "https://$domain")

    if [[ "$status_code" -eq 200 ]]; then
        return 0 # Online
    else
        return 1 # Offline or other issue
    fi
}

# Function to check if an IP is online by pinging it
check_ip_online() {
    local ip=$1
    if ping -c 3 -W 2 "$ip" >/dev/null 2>&1; then
        printf "IP %s is online\n" "$ip"
        return 0 # Online
    else
        printf "IP %s is offline\n" "$ip"
        return 1 # Offline or unreachable
    fi
}


# Function to update Cloudflare DNS A record for all subdomains except excluded ones
update_cloudflare_dns() {
    local email=$1
    local api_key=$2
    local zone_id=$3
    local domain=$4
    local new_ip=$5
    local excluded_subdomains=("${@:6}") # Remaining arguments are excluded subdomains

    # Fetch all DNS records
    local records_json

    if ! records_json=$(curl -s -X GET "$CLOUDFLARE_API_ENDPOINT/zones/$zone_id/dns_records?type=A" \
            -H "X-Auth-Email: $email" \
            -H "X-Auth-Key: $api_key" \
            -H "Content-Type: application/json"); then
        echo "Failed to fetch DNS records due to a network or curl error." >&2
        return 1
    fi

    # Check if the records_json is empty or not as expected
    if [ -z "$records_json" ] || [[ "$records_json" == *'"result":[]'* ]]; then
        echo "No DNS records found or empty response." >&2
        return 1
    fi

    # Parse the JSON response to check if the API call was successful
    local success errors
    success=$(echo "$records_json" | jq -r '.success')
    errors=$(echo "$records_json" | jq -r '.errors | length')

    # Check if the API call was not successful or there were errors
    if [[ "$success" != "true" ]] || [[ "$errors" -gt 0 ]]; then
        echo "Failed to fetch DNS records. API response marked as unsuccessful or contained errors." >&2
        echo "Error details: $(echo "$records_json" | jq -r '.errors')" >&2
        return 1
    fi

    local records_count record_name record_id
    records_count=$(echo "$records_json" | jq '.result | length')
    for ((i = 0; i < records_count; i++)); do
        record_name=$(echo "$records_json" | jq -r ".result[$i].name")
        record_id=$(echo "$records_json" | jq -r ".result[$i].id")
        subdomain_part="${record_name%."$domain"}" # Extract the subdomain part

        # Check if the subdomain part is in the excluded subdomains
        if [[ ! " ${excluded_subdomains[*]} " =~  $subdomain_part  ]]; then
            local update_response
            if ! update_response=$(curl -s -X PUT "$CLOUDFLARE_API_ENDPOINT/zones/$zone_id/dns_records/$record_id" \
                    -H "X-Auth-Email: $email" \
                    -H "X-Auth-Key: $api_key" \
                    -H "Content-Type: application/json" \
                    --data "{\"type\":\"A\",\"name\":\"$record_name\",\"content\":\"$new_ip\",\"ttl\":1,\"proxied\":true}" \
                    -w "%{http_code}"); then
                echo "Failed to update dns due to network or curl error." >&2
                return 1
            fi

            # local update_response_code
            # update_response_code=$(echo "$update_response" | tail -n1)
            update_response=$(echo "$update_response" | sed '$ d')

            # Parse the JSON response to check if the API call was successful
            local success errors
            success=$(echo "$records_json" | jq -r '.success')
            errors=$(echo "$records_json" | jq -r '.errors | length')

            # Check if the API call was not successful or there were errors
            if [[ "$success" != "true" ]] || [[ "$errors" -gt 0 ]]; then
                echo "Failed to updated DNS records. API response marked as unsuccessful or contained errors." >&2
                echo "Error details: $(echo "$records_json" | jq -r '.errors')" >&2
                return 1
            fi
            echo "$new_ip" > "$IP_CACHE_DIR/$record_name"  # Save the new IP in the cache file
            echo "Updated $record_name to $new_ip"
        else
            echo "Skipped update for $record_name as it is excluded"
        fi
    done
}

# Main function to iterate through configurations
main() {
    local domain primary_ip secondary_ip email api_key zone_id excluded_subdomains cache_file cached_ip config

    mkdir -p "$IP_CACHE_DIR"
    configs=$(jq -c '.[]' <"$CONFIG_FILE")
    echo "$configs" | while IFS= read -r config; do
        domain=$(echo "$config" | jq -r '.domain')
        primary_ip=$(echo "$config" | jq -r '.primary_ip')
        secondary_ip=$(echo "$config" | jq -r '.secondary_ip')
        email=$(echo "$config" | jq -r '.email')
        api_key=$(echo "$config" | jq -r '.api_key')
        zone_id=$(echo "$config" | jq -r '.zone_id')
        mapfile -t excluded_subdomains < <(echo "$config" | jq -r '.excluded_subdomains[]')
        # excluded_subdomains=($(echo "$config" | jq -r '.excluded_subdomains[]'))
        cache_file="$IP_CACHE_DIR/$domain"
        cached_ip=$(cat "$cache_file" 2>/dev/null || echo "")

        # Start manage domain
        echo -e "\033[34mProcessing domain: $domain\033[0m"

        printf "Cached IP %s for domain %s \n" "$cached_ip" "$domain"
        # Print each subdomain in the excluded_subdomains array
        printf "Excluded subdomains:\n"
        for subdomain in "${excluded_subdomains[@]}"; do
            printf " - %s\n" "$subdomain"
        done

        # Check if domain is online first
        if check_domain_online "$domain"; then
            printf "%s is online. Checking IP consistency...\n" "$domain"
            if [[ "$cached_ip" != "$primary_ip" ]]; then
                if check_ip_online "$primary_ip"; then
                    printf "Primary IP %s is online and different from cached IP %s. Updating DNS...\n" "$primary_ip" "$cached_ip"
                    update_cloudflare_dns "$email" "$api_key" "$zone_id" "$domain" "$primary_ip" "${excluded_subdomains[@]}"
                else
                    printf "Primary IP %s is offline. Checking secondary IP...\n" "$primary_ip"
                    if check_ip_online "$secondary_ip"; then
                        printf "Continuing to use secondary IP %s for %s.\n" "$secondary_ip" "$domain"
                    else
                        printf "Both primary and secondary IPs are offline. Urgent attention required!\n"
                    fi
                fi
            elif [[ "$cached_ip" == "$primary_ip" ]]; then
                printf "Current IP %s for %s is still valid and online. No action needed.\n" "$primary_ip" "$domain"
            else
                if check_ip_online "$secondary_ip"; then
                    printf "Continuing to use secondary IP %s for %s.\n" "$secondary_ip" "$domain"
                else
                    printf "Both primary and secondary IPs are offline. Urgent attention required!\n"
                fi
            fi
        else
            echo -e "\033[31mError: $domain is offline. Changing failover IP...\033[0m"
            if check_ip_online "$primary_ip"; then
                update_cloudflare_dns "$email" "$api_key" "$zone_id" "$domain" "$primary_ip" "${excluded_subdomains[@]}"
                printf "Switched to primary IP %s for %s due to domain being offline.\n" "$primary_ip" "$domain"
            elif check_ip_online "$secondary_ip"; then
                update_cloudflare_dns "$email" "$api_key" "$zone_id" "$domain" "$secondary_ip" "${excluded_subdomains[@]}"
                printf "Switched to secondary IP %s for %s due to primary IP failure.\n" "$secondary_ip" "$domain"
            else
                echo -e "\033[33mCritical Error: Both primary and secondary IPs for $domain are offline. Urgent attention required!\033[0m"
            fi
        fi

    done
}

# Run the main function
main
