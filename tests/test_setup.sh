#!/usr/bin/env bash
# Tests for the parts of setup.sh that do not need a server: run with  bash tests/test_setup.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=setup.sh
source "$ROOT/setup.sh"
set +e # the tests check exit codes themselves

PASSED=0
FAILED=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

check() {
	# check NAME EXPECTED ACTUAL
	if [[ "$2" == "$3" ]]; then
		PASSED=$((PASSED + 1))
	else
		FAILED=$((FAILED + 1))
		printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
	fi
}

# Host names
DOMAIN="" PUBLIC_IP="3.120.1.2"
check "sslip.io name from the IP" "shop.3-120-1-2.sslip.io" "$(host_for shop)"
DOMAIN="example.com"
check "name under a domain" "booking.example.com" "$(host_for booking)"

# Arguments
check "domain is lowercased" "example.org" "$(parse_args --domain Example.ORG && echo "$DOMAIN")"
for bad in "https://example.com" "example" "a b.com" "-x.com"; do
	(parse_args --domain "$bad") 2>/dev/null
	check "bad domain '$bad' is refused" 1 $?
done
(parse_args --nonsense) 2>/dev/null
check "unknown argument is refused" 1 $?

# .env lines
printf 'DJANGO_SECRET_KEY=keep-me\nDJANGO_ALLOWED_HOSTS=old.example.com,127.0.0.1\n' >"$WORK/.env"
set_env "$WORK/.env" DJANGO_ALLOWED_HOSTS "new.example.com,127.0.0.1,localhost"
set_env "$WORK/.env" DJANGO_CSRF_TRUSTED_ORIGINS "https://new.example.com"
check "a line is replaced" "DJANGO_ALLOWED_HOSTS=new.example.com,127.0.0.1,localhost" \
	"$(grep '^DJANGO_ALLOWED_HOSTS=' "$WORK/.env")"
check "a missing line is added" "DJANGO_CSRF_TRUSTED_ORIGINS=https://new.example.com" \
	"$(grep '^DJANGO_CSRF_TRUSTED_ORIGINS=' "$WORK/.env")"
check "other lines stay" "DJANGO_SECRET_KEY=keep-me" "$(grep '^DJANGO_SECRET_KEY=' "$WORK/.env")"

# ensure_env makes a new .env, but only updates the host of an existing one
mkdir -p "$WORK/app/scripts"
cat >"$WORK/app/scripts/make_env.py" <<'PY'
import sys
open(".env", "w").write(f"DJANGO_SECRET_KEY=fresh\nHOST_ARG={sys.argv[2]}\n")
PY
ensure_env "$WORK/app" "shop.example.com" >/dev/null
check "new .env comes from make_env.py --host" "HOST_ARG=shop.example.com" "$(grep '^HOST_ARG=' "$WORK/app/.env")"
ensure_env "$WORK/app" "shop.example.org" >/dev/null
check "existing secrets are kept" "DJANGO_SECRET_KEY=fresh" "$(grep '^DJANGO_SECRET_KEY=' "$WORK/app/.env")"
check "existing .env follows the host" "DJANGO_CSRF_TRUSTED_ORIGINS=https://shop.example.org" \
	"$(grep '^DJANGO_CSRF_TRUSTED_ORIGINS=' "$WORK/app/.env")"

# Waiting for the health endpoint
sleep() { :; }
CURL_CALLS=0
# shellcheck disable=SC2032 # only wait_healthy's own curl calls are faked, not sudo curl
curl() {
	CURL_CALLS=$((CURL_CALLS + 1))
	[[ $CURL_CALLS -ge 3 ]]
}
wait_healthy shop.example.com
check "healthy on the third try" "0 3" "$? $CURL_CALLS"
curl() { return 22; }
HEALTH_TRIES=4
wait_healthy shop.example.com
check "gives up when it never answers" 1 $?

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ $FAILED -eq 0 ]]
