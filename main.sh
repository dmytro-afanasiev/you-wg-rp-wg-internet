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
  status   Shows the current status of wireguard vpn
  rotate   Change config to a random one from $CONFIGS_DIR
EOF
}

colorize() {
	local color=""
	case "$1" in
	GREEN) color="\033[0;32m" ;;
	RED) color="\033[31m" ;;
	YELLOW) color="\033[0;33m" ;;
	*) color="" ;;
	esac
	printf "%b" "$color"
	cat -
	printf "\033[0m"
}
info() {
	echo -n "INFO: " | colorize GREEN >&2
	echo "$@" >&2
}
err() {
	echo -n "ERROR: " | colorize RED >&2
	echo "$@" >&2
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
get_if_subnet() {
	ip -4 route show dev "$1" scope link table main | grep -v "default" | awk '{print $1}' | head -1
}
get_default_if() {
	ip route show default table main | grep -v -E 'wg|proton' | awk '/default/ {print $5}' | head -1
}
get_default_gw() {
	ip route show default table main | grep -v -E 'wg|proton' | awk '/default/ {print $3}' | head -1
}
get_wg_endpoint() {
	grep -i '^Endpoint' "$CONFIG_FILENAME" | awk -F'[=:]' '{print $2}' | tr -d ' '
}

# Accepts: (endpoint, table)
route_via_default() {
	ip route replace "$1" via "$(get_default_gw)" dev "$(get_default_if)" table "$2"
}
# Accepts: (endpoint, table)
clear_route() {
	ip route del "$1" table "$2" 2>/dev/null || true
}

# Accepts: (interface name, routing table)
setup_wg_routing_table() {
	ip route replace default dev "$1" table "$2"
}

# Accepts; (routing table, priority)
setup_all_routing_rule() {
	if ip rule show | grep -q "from all lookup $1"; then
		return 0
	fi
	ip rule add from all lookup "$1" priority "$2"
}
# Accepts: (routing table)
teardown_all_routing_rule() {
	ip rule del from all lookup "$1" 2>/dev/null || true
}

#  Accepts: (source subnet, source if, routing table)
setup_routing() {
	ip route replace "$1" dev "$2" table "$3"
}
# Accepts: (routing table)
teardown_routing_table() {
	ip route flush table "$1" 2>/dev/null || true
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

	setup_wg_routing_table "$INTERFACE_NAME" "$ROUTING_TABLE_ID"
	route_via_default "$(get_wg_endpoint)" "$ROUTING_TABLE_ID"
	setup_routing "${SOURCE_SUBNET:-$(get_if_subnet "$SOURCE_IF")}" "$SOURCE_IF" "$ROUTING_TABLE_ID"
	setup_routing "${DEVICE_SUBNET:-$(get_if_subnet "$DEVICE_IF")}" "$DEVICE_IF" "$ROUTING_TABLE_ID"
	setup_all_routing_rule "$ROUTING_TABLE_ID" "$ROUTING_RULE_PRIORITY"

	setup_rotate_cron
}
cmd_down() {
	teardown_all_routing_rule "$ROUTING_TABLE_ID"
	teardown_routing_table "$ROUTING_TABLE_ID"

	wg-quick down "$INTERFACE_NAME" 2>/dev/null || true

	teardown_rotate_cron
}

cmd_status() {
	local status ip country
	if ip="$(ip -4 -br addr show "$INTERFACE_NAME" | awk '{print $3}')"; then
		status=UP
	else
		status=DOWN
		ip='-'
	fi
	if [ -f "$CONFIG_FILENAME" ]; then
		country="$(grep -o '# [A-Z]\{2,3\}#[0-9]\+' "$CONFIG_FILENAME" | cut -d' ' -f2 | tr '#' ' ')"
	else
		country='-'
	fi

	{
		printf '%s' "$INTERFACE_NAME"
		printf '|'
		printf '%s' "$status" | colorize "$([ "$status" = UP ] && echo GREEN || echo RED)"
		printf '|'
		printf '%s' "$ip"
		printf '|'
		printf '%s' "$country"
	} | column --table -s '|' --table-columns INTERFACE,STATUS,IP,COUNTRY
}

cmd_rotate() {
	if ! ip link show "$INTERFACE_NAME" &>/dev/null; then
		err "$INTERFACE_NAME interface is not up."
		return 1
	fi
	local config="" old_endpoint="" new_endpoint=""
	old_endpoint="$(get_wg_endpoint)"
	config="$(pick_random_file_in_dir "$CONFIGS_DIR")"
	sanitize_wg_config "$config" "$CONFIG_FILENAME"
	new_endpoint="$(get_wg_endpoint)"

	route_via_default "$new_endpoint" "$ROUTING_TABLE_ID"
	wg syncconf "$INTERFACE_NAME" <(wg-quick strip "$CONFIG_FILENAME")
	if [ "$old_endpoint" != "$new_endpoint" ]; then
		clear_route "$old_endpoint" "$ROUTING_TABLE_ID"
	fi
}

cmd_version() {
	echo "$PROGRAM: $VERSION"
}

VERSION="0.0.2"
PROGRAM="${0##*/}"
COMMAND="$1"
SELF_PATH="$(dirname "$(realpath "$0")")/$PROGRAM"

# global envs that impact the bevavior
INTERFACE_NAME="${INTERFACE_NAME:-vpn}"
CONFIGS_DIR="${CONFIGS_DIR:-/etc/wireguard/$INTERFACE_NAME}"
CONFIG_FILENAME="/etc/wireguard/${INTERFACE_NAME}.conf"

ROUTING_TABLE_ID="${ROUTING_TABLE_ID:-200}"
ROUTING_RULE_PRIORITY="${ROUTING_RULE_PRIORITY:-100}"

# traffic originating from this interface will be routed to our custom wg interface
SOURCE_IF="${SOURCE_IF:-wg0}"
DEVICE_IF="${DEVICE_IF:-$(get_default_if)}"

DO_NOT_STRIP_THEIR_DNS="${DO_NOT_STRIP_THEIR_DNS:-}"

ROTATE_CRONTAB="${ROTATE_CRONTAB:-"0 */6 * * *"}"
CRON_FILENAME="${CRON_FILENAME:-vpn-rotate}"

case "$1" in
up)
	shift
	cmd_up "$@"
	;;
down)
	shift
	cmd_down "$@"
	;;
status)
	shift
	cmd_status "$@"
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
*)
	err "$(cmd_unrecognized)"
	exit 1
	;;
esac
