# ddns-scripts provider for hoster.by

Custom update script for [OpenWrt ddns-scripts](https://openwrt.org/docs/guide-user/services/ddns/client) that updates DNS A/AAAA records via the [hoster.by](https://hoster.by) REST API.

## Prerequisites

- OpenWrt with `ddns-scripts` and `curl` (with SSL) installed
- A domain managed by hoster.by with DNS hosting enabled
- API credentials (Access-Key and Secret-Key) from hoster.by control panel

```sh
opkg install ddns-scripts curl ca-certificates
```

## Installation

Copy the files to your OpenWrt router:

```sh
scp usr/lib/ddns/update_hoster_by.sh root@router:/usr/lib/ddns/
scp usr/share/ddns/default/hoster.by.json root@router:/usr/share/ddns/default/
```

## Configuration

Edit `/etc/config/ddns` on the router:

```
config service 'myddns_ipv4'
    option enabled     '1'
    option service_name 'hoster.by'
    option domain      'myhost.example.com'
    option username    'YOUR_ACCESS_KEY'
    option password    'YOUR_SECRET_KEY'
    option ip_source   'network'
    option ip_network  'wan'
    option interface   'wan'
    option check_interval '10'
    option check_unit  'minutes'
    option force_interval '72'
    option force_unit  'hours'
```

### Options explained

| Option       | Value                                                              |
|--------------|--------------------------------------------------------------------|
| `domain`     | FQDN of the record (e.g. `myhost.example.com`). Zone is derived from the last two labels. For apex records use just `example.com`. |
| `username`   | hoster.by Access-Key                                               |
| `password`   | hoster.by Secret-Key                                               |
| `param_opt`  | *(optional)* `order_id=12345` — skip automatic order lookup; `ttl=3600` — set record TTL in seconds (if omitted, existing TTL is preserved) |

### IPv6

For AAAA records, add a second service section:

```
config service 'myddns_ipv6'
    option enabled     '1'
    option use_ipv6    '1'
    option service_name 'hoster.by'
    option domain      'myhost.example.com'
    option username    'YOUR_ACCESS_KEY'
    option password    'YOUR_SECRET_KEY'
    option ip_source   'network'
    option ip_network  'wan6'
    option interface   'wan6'
```

## Testing

Run manually:

```sh
/usr/lib/ddns/dynamic_dns_updater.sh myddns_ipv4
```

Check logs:

```sh
logread | grep ddns
```

## How it works

1. Authenticates with hoster.by API using Access-Key/Secret-Key
2. Caches the JWT token in `/tmp/ddns_hoster_by_*.tok` until it expires
3. Looks up the DNS order ID for your domain (or uses `order_id` from `param_opt`)
4. Reads the current A/AAAA record
5. If the IP differs from the detected WAN IP, updates the record via PATCH

## License

GPL-2.0-only
