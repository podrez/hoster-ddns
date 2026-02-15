# update_hoster_by.sh -ddns-scripts provider for hoster.by DNS API
#
# Sourced by ddns-scripts send_update() -use 'return', never 'exit'.
#
# Configuration mapping (in /etc/config/ddns):
#   option username   ->hoster.by Access-Key
#   option password   ->hoster.by Secret-Key
#   option domain     ->FQDN  (e.g. myhost.example.com or example.com for apex)
#   option param_opt  ->optional: order_id=<id> ttl=<seconds> (omitted = keep current)
#
# SPDX-License-Identifier: GPL-2.0-only

# ── constants ────────────────────────────────────────────────────────
__API="https://serviceapi.hoster.by"
__JSONFILTER="$(command -v jsonfilter)" || true

# ── validate prerequisites ───────────────────────────────────────────
[ -z "$__JSONFILTER" ] && write_log 14 "hoster.by requires jsonfilter (package libubox)"
[ -z "$CURL_SSL" ] && write_log 14 "hoster.by requires cURL with SSL support"
[ -z "$username" ] && write_log 14 "'username' (Access-Key) not set"
[ -z "$password" ] && write_log 14 "'password' (Secret-Key) not set"
[ -z "$domain" ]   && write_log 14 "'domain' not set -use hostname@domain.tld"

# force HTTPS
use_https=1

# ── parse domain ─────────────────────────────────────────────────────
# sub.example.com  ->__HOST=sub        __DOMAIN=example.com
# example.com      ->__HOST=example.com __DOMAIN=example.com  (apex record)
__TLD="${domain##*.}"
__SLD="${domain%.*}"; __SLD="${__SLD##*.}"
__DOMAIN="${__SLD}.${__TLD}"
if [ "$domain" = "$__DOMAIN" ]; then
	__HOST="$domain"
else
	__HOST="${domain%."$__DOMAIN"}"
fi

# record type based on IP version
[ "$use_ipv6" -eq 0 ] && __RRTYPE="a" || __RRTYPE="aaaa"

write_log 7 "hoster.by: host='$__HOST' domain='$__DOMAIN' rrtype='$__RRTYPE' ip='$__IP'"

# ── parse param_opt ──────────────────────────────────────────────────
__ORDER_ID_OPT=""
__TTL=""
for __PAIR in $param_opt; do
	case "$__PAIR" in
		order_id=*) __ORDER_ID_OPT="${__PAIR#order_id=}" ;;
		ttl=*)      __TTL="${__PAIR#ttl=}" ;;
	esac
done

# ── build base curl command ──────────────────────────────────────────
__PRGBASE="$CURL -s"
# bind to specific interface/IP if configured
if [ -n "$bind_network" ]; then
	local __DEVICE
	network_get_device __DEVICE "$bind_network"
	[ -n "$__DEVICE" ] && __PRGBASE="$__PRGBASE --interface $__DEVICE"
fi
# force IP version if configured
[ "$force_ipversion" -eq 1 ] && {
	[ "$use_ipv6" -eq 0 ] && __PRGBASE="$__PRGBASE -4" || __PRGBASE="$__PRGBASE -6"
}
# custom CA cert
[ -f "$cacert" ] && __PRGBASE="$__PRGBASE --cacert $cacert"
# proxy
[ -n "$proxy" ] && __PRGBASE="$__PRGBASE --proxy $proxy"

# ── helper: HTTP transfer with retry ─────────────────────────────────
hoster_transfer() {
	# $1 = full curl command to execute
	local __CNT=0
	while : ; do
		write_log 7 "hoster.by: >>> $1"
		eval "$1"
		local __ERR=$?
		if [ $__ERR -eq 0 ]; then
			write_log 7 "hoster.by: <<< $(cat "$DATFILE" 2>/dev/null)"
			return 0
		fi
		__CNT=$(( __CNT + 1 ))
		[ "$retry_max_count" -gt 0 ] && [ $__CNT -gt "$retry_max_count" ] && \
			write_log 14 "hoster.by: transfer failed after $__CNT attempts"
		write_log 4 "hoster.by: transfer error ($__ERR), retry #$__CNT in $RETRY_SECONDS sec"
		sleep "$RETRY_SECONDS" &
		PID_SLEEP=$!
		wait $PID_SLEEP
		PID_SLEEP=0
	done
}

# ── helper: check API response ───────────────────────────────────────
hoster_check_response() {
	# $1 = context message for logs
	local __STATUS
	__STATUS=$($__JSONFILTER -i "$DATFILE" -e '@.statusCode' 2>/dev/null)
	if [ "$__STATUS" != "ok" ]; then
		local __MSG
		__MSG=$(cat "$DATFILE" 2>/dev/null)
		write_log 14 "hoster.by: $1 -API error: $__MSG"
	fi
}

# ── token cache ──────────────────────────────────────────────────────
# Sanitise domain for filename: replace dots and @ with underscores
__TOK_FILE="/tmp/ddns_hoster_by_$(echo "${domain}" | sed 's/[^a-zA-Z0-9]/_/g').tok"

__ACCESS_TOKEN=""
__USER_ID=""
__ORDER_ID=""
__EXPIRES=0

# try to read cached values
if [ -f "$__TOK_FILE" ]; then
	__ACCESS_TOKEN=$(sed -n '1p' "$__TOK_FILE")
	__USER_ID=$(sed -n '2p' "$__TOK_FILE")
	__ORDER_ID=$(sed -n '3p' "$__TOK_FILE")
	__EXPIRES=$(sed -n '4p' "$__TOK_FILE")
fi

# ── authenticate if token is expired or missing ─────────────────────
__NOW=$(date +%s)
if [ -z "$__ACCESS_TOKEN" ] || [ "$__NOW" -ge "$__EXPIRES" ]; then
	write_log 7 "hoster.by: authenticating (token missing or expired)"

	hoster_transfer "$__PRGBASE -X POST '$__API/service/account/create/token' \
		-H 'Access-Key: $username' \
		-H 'Secret-Key: $password' \
		-o '$DATFILE' 2>'$ERRFILE'"

	hoster_check_response "authentication"

	__ACCESS_TOKEN=$($__JSONFILTER -i "$DATFILE" -e '@.payload.accessToken' 2>/dev/null)
	__USER_ID=$($__JSONFILTER -i "$DATFILE" -e '@.payload.userId' 2>/dev/null)
	__EXPIRES=$($__JSONFILTER -i "$DATFILE" -e '@.payload.dateExpires' 2>/dev/null)

	[ -z "$__ACCESS_TOKEN" ] && write_log 14 "hoster.by: failed to obtain access token"
	[ -z "$__USER_ID" ]      && write_log 14 "hoster.by: failed to obtain userId"

	# invalidate cached orderId -it belongs to the new session
	__ORDER_ID=""

	write_log 7 "hoster.by: authenticated, userId=$__USER_ID expires=$__EXPIRES"
fi

# ── find order ID ────────────────────────────────────────────────────
# use param_opt override first, then cache, then look up
[ -n "$__ORDER_ID_OPT" ] && __ORDER_ID="$__ORDER_ID_OPT"

if [ -z "$__ORDER_ID" ]; then
	write_log 7 "hoster.by: looking up orderId for domain '$__DOMAIN'"

	hoster_transfer "$__PRGBASE -X GET '$__API/dns/orders' \
		-H 'Access-Token: $__ACCESS_TOKEN' \
		-H 'X-User-Id: $__USER_ID' \
		-o '$DATFILE' 2>'$ERRFILE'"

	hoster_check_response "list DNS orders"

	# iterate orders to find matching domainName
	local __IDX=0
	while : ; do
		local __DN __OID
		__DN=$($__JSONFILTER -i "$DATFILE" -e "@.payload.orders[$__IDX].domainName" 2>/dev/null) || break
		[ -z "$__DN" ] && break
		if [ "$__DN" = "$__DOMAIN" ]; then
			__OID=$($__JSONFILTER -i "$DATFILE" -e "@.payload.orders[$__IDX].id" 2>/dev/null)
			__ORDER_ID="$__OID"
			break
		fi
		__IDX=$(( __IDX + 1 ))
	done

	[ -z "$__ORDER_ID" ] && write_log 14 "hoster.by: no DNS order found for '$__DOMAIN'"
	write_log 7 "hoster.by: orderId=$__ORDER_ID"
fi

# ── save token cache ─────────────────────────────────────────────────
cat > "$__TOK_FILE" <<EOF
$__ACCESS_TOKEN
$__USER_ID
$__ORDER_ID
$__EXPIRES
EOF

# ── read current record ──────────────────────────────────────────────
write_log 7 "hoster.by: reading $__RRTYPE records for order $__ORDER_ID"

hoster_transfer "$__PRGBASE -X GET '$__API/dns/orders/$__ORDER_ID/records/$__RRTYPE' \
	-H 'Access-Token: $__ACCESS_TOKEN' \
	-H 'X-User-Id: $__USER_ID' \
	-o '$DATFILE' 2>'$ERRFILE'"

hoster_check_response "list $__RRTYPE records"

# Build the FQDN to match against -API returns names with trailing dot
# For apex record (__HOST == __DOMAIN): FQDN is "domain.tld."
# For sub record: FQDN is "hostname.domain.tld."
if [ "$__HOST" = "$__DOMAIN" ]; then
	__FQDN="${__DOMAIN}."
else
	__FQDN="${__HOST}.${__DOMAIN}."
fi

local __CURRENT_IP=""
local __IDX=0
while : ; do
	local __RNAME
	__RNAME=$($__JSONFILTER -i "$DATFILE" -e "@.payload.records[$__IDX].name" 2>/dev/null) || break
	[ -z "$__RNAME" ] && break
	if [ "$__RNAME" = "$__FQDN" ]; then
		__CURRENT_IP=$($__JSONFILTER -i "$DATFILE" -e "@.payload.records[$__IDX].records[0].content" 2>/dev/null)
		break
	fi
	__IDX=$(( __IDX + 1 ))
done

write_log 7 "hoster.by: current IP='${__CURRENT_IP:-<not found>}' desired IP='$__IP'"

# ── compare IPs ──────────────────────────────────────────────────────
if [ "$__CURRENT_IP" = "$__IP" ]; then
	write_log 7 "hoster.by: record '$__HOST' already points to $__IP -no update needed"
	return 0
fi

# ── update record ────────────────────────────────────────────────────
write_log 7 "hoster.by: updating $__RRTYPE record '$__HOST' ->$__IP"

hoster_transfer "$__PRGBASE -X PATCH '$__API/dns/orders/$__ORDER_ID/records/$__RRTYPE/$__FQDN' \
	-H 'Access-Token: $__ACCESS_TOKEN' \
	-H 'X-User-Id: $__USER_ID' \
	-H 'Content-Type: application/json' \
	-d '{\"records\":[{\"content\":\"$__IP\",\"disabled\":false}]${__TTL:+,\"ttl\":$__TTL}}' \
	-o '$DATFILE' 2>'$ERRFILE'"

hoster_check_response "update $__RRTYPE record"

write_log 7 "hoster.by: record '$__HOST' updated to $__IP"
return 0
