#!/bin/sh
# hoster-ddns.sh - DDNS updater for hoster.by on Keenetic (Entware)
#
# Requirements (Entware): opkg install curl jq
# Config:  /opt/etc/hoster-ddns.conf  (or pass path as $1)
# Install: chmod +x /opt/sbin/hoster-ddns.sh
# Cron (один домен):
#   */5 * * * * /opt/sbin/hoster-ddns.sh
# Cron (несколько доменов):
#   */5 * * * * /opt/sbin/hoster-ddns.sh /opt/etc/hoster-ddns-www.conf
#   */5 * * * * /opt/sbin/hoster-ddns.sh /opt/etc/hoster-ddns-mail.conf
#
# SPDX-License-Identifier: GPL-2.0-only

CONFIG="${1:-/opt/etc/hoster-ddns.conf}"
API="https://serviceapi.hoster.by"

# ── logging ──────────────────────────────────────────────────────────
log()   { logger -t hoster-ddns "$*"; }
fatal() { logger -t hoster-ddns "FATAL: $*"; exit 1; }
debug() { [ "${VERBOSE:-0}" -eq 1 ] && logger -t hoster-ddns "DEBUG: $*" || true; }

# ── load config ──────────────────────────────────────────────────────
[ -f "$CONFIG" ] || fatal "config not found: $CONFIG"
. "$CONFIG"

[ -z "$ACCESS_KEY" ] && fatal "'ACCESS_KEY' not set in $CONFIG"
[ -z "$SECRET_KEY" ] && fatal "'SECRET_KEY' not set in $CONFIG"
[ -z "$DOMAIN" ]     && fatal "'DOMAIN' not set in $CONFIG"

# ── validate tools ───────────────────────────────────────────────────
JQ="$(command -v jq)"     || fatal "jq not found — install: opkg install jq"
CURL="$(command -v curl)" || fatal "curl not found — install: opkg install curl"

# ── detect current IP ────────────────────────────────────────────────
# IP_SOURCE in config:
#   auto              — external IP via ipify.org (default)
#   iface:<name>      — IP from network interface (e.g. iface:ppp0)
#   url:<url>         — plain-text IP from custom URL
case "${IP_SOURCE:-auto}" in
	iface:*)
		_IFACE="${IP_SOURCE#iface:}"
		IP=$(ip -4 addr show "$_IFACE" 2>/dev/null \
			| grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
		[ -z "$IP" ] && fatal "no IPv4 address on interface $_IFACE"
		;;
	url:*)
		_URL="${IP_SOURCE#url:}"
		IP=$($CURL -sf --max-time 10 "$_URL") \
			|| fatal "failed to get IP from $_URL"
		;;
	auto|*)
		IP=$($CURL -sf --max-time 10 'https://api.ipify.org') \
		|| IP=$($CURL -sf --max-time 10 'https://ifconfig.me') \
		|| fatal "failed to detect external IP"
		;;
esac

debug "detected IP: $IP"

# ── parse domain ─────────────────────────────────────────────────────
# sub.example.com  ->  HOST=sub         ROOT=example.com
# example.com      ->  HOST=example.com ROOT=example.com  (apex)
_TLD="${DOMAIN##*.}"
_SLD="${DOMAIN%.*}"; _SLD="${_SLD##*.}"
ROOT_DOMAIN="${_SLD}.${_TLD}"
if [ "$DOMAIN" = "$ROOT_DOMAIN" ]; then
	HOST="$DOMAIN"
else
	HOST="${DOMAIN%."$ROOT_DOMAIN"}"
fi

debug "host='$HOST' root='$ROOT_DOMAIN'"

# ── token cache ──────────────────────────────────────────────────────
TOK_FILE="/tmp/hoster_ddns_$(echo "$ROOT_DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g').tok"

ACCESS_TOKEN=""
USER_ID=""
ORDER_ID=""
EXPIRES=0

if [ -f "$TOK_FILE" ]; then
	ACCESS_TOKEN=$(sed -n '1p' "$TOK_FILE")
	USER_ID=$(sed -n '2p'      "$TOK_FILE")
	ORDER_ID=$(sed -n '3p'     "$TOK_FILE")
	EXPIRES=$(sed -n '4p'      "$TOK_FILE")
fi

# ── authenticate if token is expired or missing ──────────────────────
NOW=$(date +%s)
if [ -z "$ACCESS_TOKEN" ] || [ "$NOW" -ge "${EXPIRES:-0}" ]; then
	debug "authenticating (token missing or expired)"

	RESP=$($CURL -sf --max-time 15 -X POST "$API/service/account/create/token" \
		-H "Access-Key: $ACCESS_KEY" \
		-H "Secret-Key: $SECRET_KEY") \
		|| fatal "authentication request failed (curl error)"

	_STATUS=$(echo "$RESP" | $JQ -r '.statusCode // empty')
	[ "$_STATUS" != "ok" ] && fatal "authentication failed: $RESP"

	ACCESS_TOKEN=$(echo "$RESP" | $JQ -r '.payload.accessToken // empty')
	USER_ID=$(echo "$RESP"      | $JQ -r '.payload.userId // empty')
	EXPIRES=$(echo "$RESP"      | $JQ -r '.payload.dateExpires // empty')

	[ -z "$ACCESS_TOKEN" ] && fatal "no accessToken in auth response"
	[ -z "$USER_ID" ]      && fatal "no userId in auth response"

	ORDER_ID=""  # invalidate cached orderId — it belongs to the old session
	debug "authenticated, userId=$USER_ID expires=$EXPIRES"
fi

# ── find order ID ────────────────────────────────────────────────────
# Priority: ORDER_ID_OVERRIDE from config > cache > API lookup
[ -n "${ORDER_ID_OVERRIDE:-}" ] && ORDER_ID="$ORDER_ID_OVERRIDE"

if [ -z "$ORDER_ID" ]; then
	debug "looking up orderId for '$ROOT_DOMAIN'"

	RESP=$($CURL -sf --max-time 15 -X GET "$API/dns/orders" \
		-H "Access-Token: $ACCESS_TOKEN" \
		-H "X-User-Id: $USER_ID") \
		|| fatal "list orders request failed (curl error)"

	_STATUS=$(echo "$RESP" | $JQ -r '.statusCode // empty')
	[ "$_STATUS" != "ok" ] && fatal "list orders failed: $RESP"

	ORDER_ID=$(echo "$RESP" | $JQ -r --arg d "$ROOT_DOMAIN" \
		'.payload.orders[] | select(.domainName == $d) | .id' | head -1)

	[ -z "$ORDER_ID" ] && fatal "no DNS order found for '$ROOT_DOMAIN'"
	debug "orderId=$ORDER_ID"
fi

# ── save token cache ─────────────────────────────────────────────────
printf '%s\n%s\n%s\n%s\n' \
	"$ACCESS_TOKEN" "$USER_ID" "$ORDER_ID" "$EXPIRES" > "$TOK_FILE"

# ── read current A record ────────────────────────────────────────────
debug "reading A records for order $ORDER_ID"

RESP=$($CURL -sf --max-time 15 -X GET "$API/dns/orders/$ORDER_ID/records/a" \
	-H "Access-Token: $ACCESS_TOKEN" \
	-H "X-User-Id: $USER_ID") \
	|| fatal "list A records request failed (curl error)"

_STATUS=$(echo "$RESP" | $JQ -r '.statusCode // empty')
[ "$_STATUS" != "ok" ] && fatal "list A records failed: $RESP"

# API returns record names with trailing dot
if [ "$HOST" = "$ROOT_DOMAIN" ]; then
	FQDN="${ROOT_DOMAIN}."
else
	FQDN="${HOST}.${ROOT_DOMAIN}."
fi

CURRENT_IP=$(echo "$RESP" | $JQ -r --arg n "$FQDN" \
	'.payload.records[] | select(.name == $n) | .records[0].content // empty' \
	| head -1)

debug "current='${CURRENT_IP:-<not found>}' desired='$IP'"

# ── compare IPs ──────────────────────────────────────────────────────
if [ "$CURRENT_IP" = "$IP" ]; then
	debug "record '$HOST' already points to $IP — no update needed"
	exit 0
fi

# ── update record ────────────────────────────────────────────────────
log "updating A record '$HOST' -> $IP (was: ${CURRENT_IP:-<not found>})"

_TTL_JSON=""
[ -n "${TTL:-}" ] && _TTL_JSON=",\"ttl\":$TTL"

RESP=$($CURL -sf --max-time 15 -X PATCH \
	"$API/dns/orders/$ORDER_ID/records/a/$FQDN" \
	-H "Access-Token: $ACCESS_TOKEN" \
	-H "X-User-Id: $USER_ID" \
	-H "Content-Type: application/json" \
	-d "{\"records\":[{\"content\":\"$IP\",\"disabled\":false}]$_TTL_JSON}") \
	|| fatal "update record request failed (curl error)"

_STATUS=$(echo "$RESP" | $JQ -r '.statusCode // empty')
[ "$_STATUS" != "ok" ] && fatal "update record failed: $RESP"

log "record '$HOST' updated to $IP"
