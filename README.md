# Cloudflare DNS Update Script

## Overview
This script is designed to automate the process of updating DNS records on Cloudflare for specified domains. It checks the online status of the domain, verifies IP consistency, and updates DNS records if necessary. It handles primary and secondary IP failovers and excludes certain subdomains from updates based on a predefined list.

## Features
- **Domain Checking**: Automatically checks if the domain is online.
- **IP Verification**: Verifies if the current IP matches the expected primary or secondary IP.
- **DNS Update**: Updates the DNS record on Cloudflare if the IP address changes.
- **Failover Handling**: Switches to a secondary IP if the primary IP is offline.
- **Exclusion List**: Allows users to specify subdomains that should not be updated.

## Requirements
- `jq`: This script uses jq for JSON parsing. Make sure it's installed on your system.
- `curl`: Used for making API calls to Cloudflare.
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
        "excluded_subdomains": ["sub1.example.com", "sub2.example.com"]
    }
]
```

## Usage

To run the script, simply execute it from the command line:

```bash
./cloudflare_dns_updater.sh
```

The script will process each domain defined in your domain.json file. It will check if the domain is online, compare the current IP against the primary and secondary IPs, and update the DNS records on Cloudflare if necessary.

## Logging

The script provides detailed logging for each step it performs, including:

- Checking if the domain is online.
- IP verification results.
- Status of DNS record updates.
- Failovers to secondary IPs.

All error messages are directed to standard error (stderr), which can be redirected to a file for troubleshooting purposes.

## Customization

You can customize the script by modifying the `domain.json` file to include new domains or change IP addresses. The list of excluded subdomains can also be updated as per your requirements.

## Error Handling

The script includes robust error handling to deal with network issues, API errors, and unexpected responses from Cloudflare. Error logs provide detailed information that can help in troubleshooting.

## Automating Checks and Updates

To ensure that your DNS records are continuously monitored and updated without manual intervention, you can automate the execution of this script using cron on a Linux system. Here’s how to set it up:
Setting up a Cron Job

1. Open the crontab editor:  

Open your terminal and type the following command to edit the crontab for the current user:

```bash
crontab -e
```

2. Add a cron job:
In the crontab editor, add a line that specifies how often you want the script to run. For example, to run the script every hour, you would add:

```bash

    0 * * * * /path/to/your/cloudflare_dns_updater.sh >> /path/to/your/logfile.log 2>&1
```
  
This setup directs both stdout and stderr to logfile.log, allowing you to keep logs of the script’s output for troubleshooting and verification purposes.

3. Save and exit the editor:

Save your changes and exit the editor. The cron service will automatically pick up the new job and begin executing it at the specified interval.

