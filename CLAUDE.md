# hoster-ddns

Custom ddns-scripts provider for hoster.by DNS API on OpenWrt.

## Project structure

```
usr/lib/ddns/update_hoster_by.sh        # update script sourced by ddns-scripts
usr/share/ddns/default/hoster.by.json   # service definition
```

## How it works

The script is **sourced** (not executed) inside ddns-scripts' `send_update()` function. It must use `return` (never `exit`) and has access to all ddns-scripts variables (`$__IP`, `$domain`, `$username`, `$password`, `$CURL`, `$DATFILE`, `$ERRFILE`, `write_log`, etc.).

**Note:** `jsonfilter` is NOT a ddns-scripts variable. The script resolves it via `command -v jsonfilter`.

## hoster.by API

- Base URL: `https://serviceapi.hoster.by`
- Auth: `POST /service/account/create/token` with `Access-Key` / `Secret-Key` headers → JWT `accessToken` + `userId`
- Subsequent calls use `Access-Token` / `X-User-Id` headers
- DNS records: `GET /dns/orders/{id}/records/a`, `PATCH /dns/orders/{id}/records/a/{name}`
- Response envelope: `{ "httpCode": 200, "statusCode": "ok", "payload": { ... } }`

## Config mapping

| ddns option      | hoster.by meaning                        |
|------------------|------------------------------------------|
| `username`       | Access-Key                               |
| `password`       | Secret-Key                               |
| `domain`         | FQDN (e.g. `www.ex.com` or `ex.com` for apex) |
| `param_opt`      | `order_id=<id>` (optional, skips lookup) `ttl=<seconds>` (optional, keeps current if omitted) |

## Token caching

Cached in `/tmp/ddns_hoster_by_<domain>.tok` (4 lines: accessToken, userId, orderId, expiry). Reused until expired.

## Shell conventions

- Target shell: busybox ash (OpenWrt)
- No bashisms — POSIX sh only
- JSON parsing via OpenWrt's `jsonfilter` (libubox)
- `write_log 14` = fatal, `write_log 4` = warning, `write_log 7` = debug
