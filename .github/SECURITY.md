# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest  | Yes       |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT open a public issue**
2. Email the maintainer or use [GitHub's private vulnerability reporting](https://github.com/skinner12/CFDNSAutoSync/security/advisories/new)
3. Include a description of the vulnerability and steps to reproduce

You can expect an initial response within 48 hours.

## Security Considerations

- **API keys**: Never commit `domain.json` to version control. The `.gitignore` excludes `*.json` files by default.
- **Bot tokens**: Telegram bot tokens and Slack webhook URLs are sensitive. Treat them like passwords.
- **File permissions**: The script stores cache and logs in `~/.cloudflare_dns_updater/`. Ensure this directory has appropriate permissions (`chmod 700`).
- **Docker**: When using Docker, mount `domain.json` as read-only (`:ro`) to prevent accidental modifications.
