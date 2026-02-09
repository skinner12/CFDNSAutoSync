# Contributing

Contributions are welcome! Here's how to get started.

## Setup

1. Fork and clone the repository
2. Install dependencies: `jq`, `curl`, `bc`, `shellcheck`
3. Copy `domain.json.example` to `domain.json` and configure with your test credentials

## Development

```bash
# Run in dry-run mode (no DNS changes)
./cloudflare_dns_updater.sh --dry-run

# Lint the script
shellcheck cloudflare_dns_updater.sh

# Test with a custom config
./cloudflare_dns_updater.sh --config test-config.json --dry-run
```

## Submitting Changes

1. Create a feature branch from `develop`: `git checkout -b feat/your-feature`
2. Make your changes
3. Ensure `shellcheck` passes with no warnings
4. Test with `--dry-run`
5. Commit using [conventional commits](https://www.conventionalcommits.org/):
   - `feat(scope): add new feature` (triggers minor version bump)
   - `fix(scope): fix a bug` (triggers patch version bump)
   - `docs(scope): update documentation` (triggers patch version bump)
6. Push and open a Pull Request against `develop`

## Code Style

- Use tabs for indentation in `.sh` files
- All output goes through the `log_message` function
- Keep functions focused and well-named
- Avoid external dependencies beyond `jq`, `curl`, `bc`

## Reporting Issues

- Use the provided issue templates
- Include your script version (`--version`), OS, and relevant log output
- Remove any sensitive data (API keys, emails) before posting
