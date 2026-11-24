#!/usr/bin/env bash
# Dumps both PostgreSQL databases and the MongoDB catalogue into ~/backups and deletes
# dumps older than a week. setup.sh runs it every night from /etc/cron.d/portfolio-backup.
set -euo pipefail

APPS_DIR="${APPS_DIR:-$HOME/apps}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
KEEP_DAYS=7
STAMP="$(date -u +%Y%m%d-%H%M%S)"

dump() {
	# dump APP FILE COMMAND...: run COMMAND in the app's containers, keep its output as FILE.
	local app=$1 file="$BACKUP_DIR/$2"
	shift 2
	(cd "$APPS_DIR/$app" && docker compose exec -T "$@") >"$file"
	[[ -s "$file" ]] || {
		echo "backup.sh: $file is empty" >&2
		exit 1
	}
	echo "$(date -u '+%F %T') $file $(du -h "$file" | cut -f1)"
}

mkdir -p "$BACKUP_DIR"
dump shop-finder-api "shopfinder-postgres-$STAMP.dump" postgres pg_dump -U shopfinder -d shopfinder --format=custom
dump shop-finder-api "shopfinder-mongo-$STAMP.archive.gz" mongo mongodump --quiet --archive --gzip --db shopfinder
dump booking-api "bookingapi-postgres-$STAMP.dump" postgres pg_dump -U bookingapi -d bookingapi --format=custom
find "$BACKUP_DIR" \( -name '*.dump' -o -name '*.archive.gz' \) -mtime +"$KEEP_DAYS" -delete
