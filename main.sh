#!/bin/bash

set -eo pipefail

cmd_usage() {
	cat <<EOF
Usage:
  $PROGRAM [command]

Available Commands:
  help     Show this message and exit
  version  Show version
  up       Setup wg interface and configure routing
  down     Delete wg interface and restore routing
  rotate   Change config to a random one from $CONFIGS_DIR
EOF
}

info() {
	echo "INFO:" "$@" >&2
}
err() {
	echo "ERROR:" "$@" >&2
}
die() {
	err "$@"
	exit 1
}
cmd_unrecognized() {
	cat <<EOF
'$COMMAND' is not recognized. See '$PROGRAM --help'
EOF
}

# picks a random file from the given directory
pick_random_file_in_dir() {
	if [ ! -d "$1" ]; then
		err "$1 does not exist"
		return 1
	fi
	local file=""
	file=$(find "$1" -maxdepth 1 -type f -name "*.conf" -print0 | shuf -z -n 1 | xargs -0 -r realpath)
	if [ -z "$file" ]; then
		err "no files found in $1"
		return 1
	fi
	printf '%s\n' "$file"
}

# accepts the source filepath and destination filepath. Prepares the wg config while moving
sanitize_wg_config() {
	if [ ! -f "$1" ]; then
		err "$1 does not exist"
		return 1
	fi
	cp --force "$1" "$2"

	# What needs to be done:
	# - add Table = off, so wg-quick does not routing
	# - remove DNS = ... since we assume our RP has our own adguard home
	# - remove ipv6 component from Address
	if ! grep -q "^Table" "$2"; then
		sed -i '/^\[Interface\]/a Table = off' "$2"
	fi
	if [ -z "$DO_NOT_STRIP_THEIR_DNS" ]; then
		sed -i 's/^\s*DNS\s*=/# &/' "$2"
	fi
	sed -i -E 's/^(Address = ([^,]+),.+)$/# \1\nAddress = \2/' "$2"
}

get_default_if() {
	ip route show default | grep -v -E 'wg|proton' | awk '/default/ {print $5}' | head -1
}
get_default_gw() {
	ip route show default | grep -v -E 'wg|proton' | awk '/default/ {print $3}' | head -1
}
get_wg_endpoint() {
	grep -i '^Endpoint' "$CONFIG_FILENAME" | awk -F'[=:]' '{print $2}' | tr -d ' '
}

route_via_default() {
	ip route replace "$1" via "$(get_default_gw)" dev "$(get_default_if)"
}
clear_route() {
	ip route del "$1" 2>/dev/null || true
}

setup_routing_from_subnet_to_wg() {
	ip route replace default dev "$INTERFACE_NAME" table "$ROUTING_TABLE_ID"
	if ip rule show | grep -q "from $SOURCE_SUBNET lookup $ROUTING_TABLE_ID"; then
		return 0
	fi
	ip rule add from "$SOURCE_SUBNET" lookup "$ROUTING_TABLE_ID" priority "$ROUTING_RULE_PRIORITY"
	ip route replace "$SOURCE_SUBNET" dev "${SOURCE_IF}" table "$ROUTING_TABLE_ID"

}
teardown_routing_from_subnet_to_wg() {
	ip route flush table "$ROUTING_TABLE_ID" 2>/dev/null || true
	ip rule del from "$SOURCE_SUBNET" lookup "$ROUTING_TABLE_ID" 2>/dev/null || true
}

setup_rotate_cron() {
	mkdir -p /etc/cron.d/
	cat <<EOF >/etc/cron.d/"$CRON_FILENAME"
# Created by $SELF_PATH
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

$ROTATE_CRONTAB root $SELF_PATH rotate
EOF
}
teardown_rotate_cron() {
	rm -f /etc/cron.d/"$CRON_FILENAME" || true
}

cmd_up() {
	if ip link show "$INTERFACE_NAME" &>/dev/null; then
		info "$INTERFACE_NAME interface is already up."
		return 0
	fi
	local config=""
	config="$(pick_random_file_in_dir "$CONFIGS_DIR")"
	sanitize_wg_config "$config" "$CONFIG_FILENAME"

	wg-quick up "$INTERFACE_NAME"

	route_via_default "$(get_wg_endpoint)"
	setup_routing_from_subnet_to_wg

	setup_rotate_cron
}
cmd_down() {
	local endpoint=""
	if endpoint="$(get_wg_endpoint)"; then
		clear_route "$endpoint"
	fi
	teardown_routing_from_subnet_to_wg

	wg-quick down "$INTERFACE_NAME" 2>/dev/null || true

	# TODO: remove rotation cron
	teardown_rotate_cron
}

cmd_rotate() {
	if ! ip link show "$INTERFACE_NAME" &>/dev/null; then
		err "$INTERFACE_NAME interface is not up."
		return 1
	fi
	local config="" old_endpoint=""
	old_endpoint="$(get_wg_endpoint)"
	config="$(pick_random_file_in_dir "$CONFIGS_DIR")"
	sanitize_wg_config "$config" "$CONFIG_FILENAME"

	wg syncconf "$INTERFACE_NAME" <(wg-quick strip "$CONFIG_FILENAME")

	clear_route "$old_endpoint"
	route_via_default "$(get_wg_endpoint)"
}

cmd_version() {
	echo "$PROGRAM: $VERSION"
}

VERSION="0.0.1"
PROGRAM="${0##*/}"
COMMAND="$1"
SELF_PATH="$(dirname "$(realpath "$0")")/$PROGRAM"

# global envs that impact the bevavior. Prefixed with RP_
INTERFACE_NAME="${INTERFACE_NAME:-vpn}"
CONFIGS_DIR="${CONFIGS_DIR:-/etc/wireguard/$INTERFACE_NAME}"
CONFIG_FILENAME="/etc/wireguard/${INTERFACE_NAME}.conf"

ROUTING_TABLE_ID="${ROUTING_TABLE_ID:-200}"
ROUTING_RULE_PRIORITY="${ROUTING_RULE_PRIORITY:-100}"

# traffic originating from this subnet will be routed to our custom wg interface
# it's supposed to be your local wg subnet
SOURCE_SUBNET="${SOURCE_SUBNET:-10.154.100.0/24}"
SOURCE_IF="${SOURCE_IF:-wg0}"

DO_NOT_STRIP_THEIR_DNS="${DO_NOT_STRIP_THEIR_DNS:-}"

ROTATE_CRONTAB="${ROTATE_CRONTAB:-"0 */6 * * *"}"
CRON_FILENAME="${CRON_FILENAME:-vpn-rotate.sh}"

case "$1" in
up)
	shift
	cmd_up "$@"
	;;
down)
	shift
	cmd_down "$@"
	;;
rotate)
	shift
	cmd_rotate "$@"
	;;
help | -h | --help)
	shift
	cmd_usage "$@"
	;;
version | --version)
	shift
	cmd_version "$@"
	;;
'')
	cmd_usage
	;;
*) die "$(cmd_unrecognized)" ;;
esac
