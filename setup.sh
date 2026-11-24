#!/usr/bin/env bash
# Sets up a fresh Ubuntu server (an AWS EC2 instance) to run shop-finder-api and
# booking-api behind Caddy, or updates a server that already runs them. Safe to run again.
#
#   bash setup.sh                        # host names from the public IP: shop.3-120-1-2.sslip.io
#   bash setup.sh --domain example.com   # shop.example.com and booking.example.com
#
# Everything it prints also goes to ~/setup-<time>.log.
set -euo pipefail

VERSION="0.1.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-$HOME/apps}"
GITHUB_OWNER="${GITHUB_OWNER:-lecorrr}"
SWAP_FILE=/swapfile
SWAP_SIZE=2G
# Five seconds apart: three minutes for migrations, container health and certificates.
HEALTH_TRIES=36
# Repository and the first label of its host name. Each app's local port is fixed in its
# own compose.yaml and in the Caddyfile here: shop-finder-api 8020, booking-api 8030.
APPS=("shop-finder-api shop" "booking-api booking")
HOST_NAME='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

DOMAIN=""
PUBLIC_IP=""

say() { printf '\n== %s\n' "$*"; }
die() {
	printf 'setup.sh: %s\n' "$*" >&2
	exit 1
}

usage() {
	sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--domain)
			[[ $# -ge 2 ]] || die "--domain needs a value, like --domain example.com"
			DOMAIN="${2,,}"
			[[ "$DOMAIN" =~ $HOST_NAME ]] || die "'$2' is not a domain like example.com"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "unknown argument '$1' (see --help)" ;;
		esac
	done
}

check_system() {
	grep -q '^ID=ubuntu$' /etc/os-release 2>/dev/null || die "this script is for Ubuntu"
	[[ $EUID -ne 0 ]] || die "run it as your normal user (ubuntu), not with sudo"
	sudo -n true 2>/dev/null || die "the user needs sudo without a password, like ubuntu on EC2"
	# A fresh instance is still installing updates for a few minutes after boot.
	if command -v cloud-init >/dev/null; then
		sudo cloud-init status --wait >/dev/null || echo "cloud-init reported a problem; carrying on"
	fi
}

apt_get() {
	# Waits up to 5 minutes when unattended upgrades hold the package lock.
	sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -q "$@"
}

ensure_swap() {
	if [[ -n "$(swapon --show --noheadings)" ]]; then
		echo "swap is already on: $(swapon --show --noheadings | awk '{print $1, $3}')"
		return
	fi
	sudo fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
	sudo chmod 600 "$SWAP_FILE"
	sudo mkswap "$SWAP_FILE" >/dev/null
	sudo swapon "$SWAP_FILE"
	grep -q "^$SWAP_FILE " /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
	# Only swap when memory is really short; it is a safety net, not extra memory.
	echo "vm.swappiness=10" | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
	sudo sysctl -q -p /etc/sysctl.d/99-swappiness.conf
	echo "swap on: $SWAP_SIZE in $SWAP_FILE"
}

ensure_docker() {
	if command -v docker >/dev/null; then
		echo "docker is already installed: $(docker --version)"
	else
		install_docker
	fi
	ensure_log_rotation
	# Takes effect at the next login; this script itself uses sudo.
	sudo usermod -aG docker "$USER"
}

install_docker() {
	# The apt repository steps from https://docs.docker.com/engine/install/ubuntu/
	local codename arch
	apt_get update
	apt_get install -y ca-certificates curl
	sudo install -m 0755 -d /etc/apt/keyrings
	sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
	sudo chmod a+r /etc/apt/keyrings/docker.asc
	# shellcheck source=/dev/null
	codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
	arch="$(dpkg --print-architecture)"
	sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF
	apt_get update
	apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	echo "installed $(docker --version)"
}

ensure_log_rotation() {
	local config=/etc/docker/daemon.json
	if sudo test -f "$config"; then
		echo "keeping the existing $config"
		return
	fi
	# Container logs grow without limit by default: keep three files of 10 MB per container.
	echo '{"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' |
		sudo tee "$config" >/dev/null
	sudo systemctl restart docker
	echo "container logs are now rotated (10 MB x 3)"
}

public_ip() {
	# Instance metadata (IMDSv2): ask for a token first, then the address.
	local token
	token="$(curl -fsS --max-time 3 -X PUT http://169.254.169.254/latest/api/token \
		-H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" || return 1
	curl -fsS --max-time 3 -H "X-aws-ec2-metadata-token: $token" \
		http://169.254.169.254/latest/meta-data/public-ipv4
}

host_for() {
	# host_for PREFIX: the public name of one app.
	if [[ -n "$DOMAIN" ]]; then
		echo "$1.$DOMAIN"
	else
		# sslip.io answers DNS queries for names with an IP inside: x.3-120-1-2.sslip.io is 3.120.1.2
		echo "$1.${PUBLIC_IP//./-}.sslip.io"
	fi
}

ensure_repo() {
	# ensure_repo NAME: clone the repository, or bring it up to date.
	local dir="$APPS_DIR/$1"
	if [[ -d "$dir/.git" ]]; then
		git -C "$dir" pull --ff-only --quiet
	else
		git clone --quiet "https://github.com/$GITHUB_OWNER/$1.git" "$dir"
	fi
	[[ -f "$dir/compose.prod.yaml" ]] ||
		die "$1 has no compose.prod.yaml: push version 0.1.1 or newer to GitHub first"
	echo "$1 at $(git -C "$dir" log -1 --format='%h %s')"
}

set_env() {
	# set_env FILE KEY VALUE: replace the KEY= line, or add it at the end.
	local file=$1 key=$2 value=$3
	if grep -q "^$key=" "$file"; then
		sed -i "s|^$key=.*|$key=$value|" "$file"
	else
		printf '%s=%s\n' "$key" "$value" >>"$file"
	fi
}

ensure_env() {
	# ensure_env DIR HOST
	local dir=$1 host=$2
	if [[ ! -f "$dir/.env" ]]; then
		(cd "$dir" && python3 scripts/make_env.py --host "$host")
		return
	fi
	# Keep the secrets: the database was created with this password. Only follow the host.
	set_env "$dir/.env" DJANGO_ALLOWED_HOSTS "$host,127.0.0.1,localhost"
	set_env "$dir/.env" DJANGO_CSRF_TRUSTED_ORIGINS "https://$host"
	echo "kept $dir/.env, host set to $host"
}

start_app() {
	# start_app DIR: build the image and start or update every container of the app.
	(cd "$1" && sudo docker compose -f compose.yaml -f compose.prod.yaml up -d --build --remove-orphans)
}

start_proxy() {
	printf 'SHOP_HOST=%s\nBOOKING_HOST=%s\n' "$1" "$2" >"$HERE/.env"
	# Recreate, so a changed Caddyfile or host name always takes effect.
	(cd "$HERE" && sudo docker compose up -d --force-recreate)
}

install_backups() {
	mkdir -p "$HOME/backups"
	echo "17 3 * * * $USER bash $HERE/backup.sh >> $HOME/backups/backup.log 2>&1" |
		sudo tee /etc/cron.d/portfolio-backup >/dev/null
	echo "nightly backups at 03:17 UTC into $HOME/backups, kept for 7 days"
}

wait_healthy() {
	# wait_healthy HOST: succeed once https://HOST/api/v1/health/ answers 200.
	local try
	for ((try = 1; try <= HEALTH_TRIES; try++)); do
		if curl -fsS --max-time 10 -o /dev/null "https://$1/api/v1/health/" 2>/dev/null; then
			return 0
		fi
		sleep 5
	done
	return 1
}

summary() {
	local entry repo prefix host failed=0
	say "summary: setup.sh $VERSION"
	for entry in "${APPS[@]}"; do
		read -r repo prefix <<<"$entry"
		host="$(host_for "$prefix")"
		if wait_healthy "$host"; then
			printf '  %-16s ok      https://%s/api/v1/docs/\n' "$repo" "$host"
		else
			printf '  %-16s FAILED  https://%s/api/v1/health/ did not answer\n' "$repo" "$host"
			failed=1
		fi
	done
	echo
	sudo docker ps --format '  {{.Names}}\t{{.Status}}' | sort
	echo
	free -m | awk 'NR == 2 {printf "  memory  %s MB used of %s\n", $3, $2} NR == 3 {printf "  swap    %s MB used of %s\n", $3, $2}'
	df -h / | awk 'NR == 2 {printf "  disk    %s used of %s\n", $3, $2}'
	echo "  log     $LOG"
	if [[ $failed -ne 0 ]]; then
		echo
		echo "  Something did not come up. These show why:"
		echo "    sudo docker compose -f ~/apps/shop-finder-api/compose.yaml logs --tail 50 api"
		echo "    sudo docker compose -f ~/portfolio-server/compose.yaml logs --tail 50 caddy"
		return 1
	fi
	echo
	echo "  Log out and back in once, then docker works without sudo."
}

main() {
	parse_args "$@"
	LOG="$HOME/setup-$(date -u +%Y%m%d-%H%M%S).log"
	exec > >(tee -a "$LOG") 2>&1
	say "setup.sh $VERSION on $(hostname), $(date -u '+%Y-%m-%d %H:%M UTC')"
	check_system

	say "swap"
	ensure_swap
	say "docker"
	ensure_docker

	if [[ -z "$DOMAIN" ]]; then
		PUBLIC_IP="$(public_ip)" ||
			die "no public IP found; give the instance an Elastic IP, or use --domain"
	fi
	mkdir -p "$APPS_DIR"
	local entry repo prefix host
	for entry in "${APPS[@]}"; do
		read -r repo prefix <<<"$entry"
		host="$(host_for "$prefix")"
		say "$repo for https://$host"
		ensure_repo "$repo"
		ensure_env "$APPS_DIR/$repo" "$host"
		start_app "$APPS_DIR/$repo"
	done

	say "proxy"
	start_proxy "$(host_for shop)" "$(host_for booking)"
	say "backups"
	install_backups
	summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
