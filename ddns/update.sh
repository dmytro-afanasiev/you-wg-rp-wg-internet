#!/bin/bash

set -eo pipefail

: "${DOMAIN:?DOMAIN env must be set}"
: "${TOKEN:?TOKEN env must be set}"

ROUTER_USER="${ROUTER_USER:-root}"
ROUTER_IP="${ROUTER_IP:-192.168.1.1}"

IP_FILE="${IP_FILE:-/tmp/public_ipv4}"

LOGGER_TAG="${LOGGER_TAG:-ddns}"

get_my_ip() {
	ssh "$ROUTER_USER@$ROUTER_IP" ifstatus wan | jq -r '."ipv4-address"[0].address'
}

# Accepts: (public ip)
build_duckdns_update_url() {
	echo 'https://www.duckdns.org/update?domains='"$DOMAIN"'&token='"$TOKEN"'&ip='"$1"
}


if ! _ip="$(get_my_ip)"; then
	logger -p3 -t "$LOGGER_TAG" "Could not get public ipv4 from router"
	exit 1
fi

if [ -f "$IP_FILE" ] && [ "$(cat "$IP_FILE")" = "$_ip" ]; then
	logger -p6 -t "$LOGGER_TAG" "Public IP didn't change"
	exit 0
fi

if ! _resp="$(curl -4 -sSfL "$(build_duckdns_update_url "$_ip")" 2>&1)"; then
	logger -p3 -t "$LOGGER_TAG" "$_resp"
	exit 1
fi
logger -p6 -t "$LOGGER_TAG" "$_resp"
logger -p6 -t "$LOGGER_TAG" "Writing '$_ip' > '$IP_FILE'"

echo "$_ip" > "$IP_FILE"
