# Changelog

## 0.1.0 (2026-11-25)

First version.

- `setup.sh`: swap, Docker with log rotation, both projects from GitHub with
  `compose.prod.yaml`, Caddy with automatic HTTPS (sslip.io names or `--domain`), nightly
  backups, and a summary that checks both APIs over HTTPS. Safe to run again to update.
- `backup.sh`: `pg_dump` of both databases and `mongodump` of the catalogue, kept 7 days.
- CI: ShellCheck, the script tests and a Caddyfile validation.
