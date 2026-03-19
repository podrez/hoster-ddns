# ddns provider for hoster.by

Обновляет DNS A-записи через [REST API hoster.by](https://serviceapi.hoster.by). Поддерживает два варианта установки: **OpenWrt** (через ddns-scripts) и **Keenetic** (Entware, standalone-скрипт + cron).

Токен и ORDER_ID кэшируются по корневому домену — субдомены одного домена делят общий кэш и не тратят лишних запросов на аутентификацию.

---

## OpenWrt

### Требования

- `ddns-scripts`, `curl` (с SSL), `libubox` (jsonfilter)

```sh
opkg install ddns-scripts curl ca-certificates
```

### Установка

```sh
scp usr/lib/ddns/update_hoster_by.sh    root@router:/usr/lib/ddns/
scp usr/share/ddns/default/hoster.by.json root@router:/usr/share/ddns/default/
```

### Настройка

`/etc/config/ddns`:

```
config service 'myddns_ipv4'
    option enabled      '1'
    option service_name 'hoster.by'
    option domain       'myhost.example.com'
    option username     'YOUR_ACCESS_KEY'
    option password     'YOUR_SECRET_KEY'
    option ip_source    'network'
    option ip_network   'wan'
    option interface    'wan'
    option check_interval '10'
    option check_unit   'minutes'
    option force_interval '72'
    option force_unit   'hours'
```

| Опция       | Значение |
|-------------|----------|
| `domain`    | FQDN записи (`myhost.example.com`). Зона берётся из двух последних меток. Для apex — `example.com`. |
| `username`  | Access-Key из панели hoster.by |
| `password`  | Secret-Key из панели hoster.by |
| `param_opt` | *(необязательно)* `order_id=12345` — пропустить авто-поиск ордера; `ttl=3600` — TTL в секундах |

Для AAAA-записи добавьте второй блок `service` с `option use_ipv6 '1'` и `ip_network 'wan6'`.

### Проверка

```sh
/usr/lib/ddns/dynamic_dns_updater.sh myddns_ipv4
logread | grep ddns
```

---

## Keenetic (Entware)

### Требования

Установленный Entware и пакеты:

```sh
opkg install curl jq
```

### Установка

```sh
cp keenetic/opt/sbin/hoster-ddns.sh /opt/sbin/
chmod +x /opt/sbin/hoster-ddns.sh
```

### Настройка

Создайте `/opt/etc/hoster-ddns.conf` (пример в `keenetic/opt/etc/hoster-ddns.conf.example`):

```sh
ACCESS_KEY="ваш-access-key"
SECRET_KEY="ваш-secret-key"
DOMAIN="myhost.example.com"

# Необязательно:
# ORDER_ID_OVERRIDE="12345"   # пропустить авто-поиск ордера
# TTL=300                     # TTL в секундах
# IP_SOURCE="auto"            # auto | iface:ppp0 | url:https://...
# VERBOSE=1                   # подробное логирование
```

Проверьте вручную:

```sh
VERBOSE=1 /opt/sbin/hoster-ddns.sh
```

Добавьте в cron:

```sh
echo "*/5 * * * * /opt/sbin/hoster-ddns.sh" >> /opt/etc/crontabs/root
/opt/etc/init.d/S10crond restart
```

### Несколько доменов

Создайте отдельный конфиг на каждый домен и укажите его как аргумент:

```sh
cp keenetic/opt/etc/hoster-ddns.conf.example /opt/etc/hoster-ddns-www.conf
cp keenetic/opt/etc/hoster-ddns.conf.example /opt/etc/hoster-ddns-mail.conf
# отредактируйте DOMAIN в каждом файле
```

`/opt/etc/crontabs/root`:

```
*/5 * * * * /opt/sbin/hoster-ddns.sh /opt/etc/hoster-ddns-www.conf
*/5 * * * * /opt/sbin/hoster-ddns.sh /opt/etc/hoster-ddns-mail.conf
```

Субдомены одного корневого домена (например `www.example.com` и `mail.example.com`) автоматически используют общий кэш токена — повторной аутентификации не происходит.

### Логи

```sh
logread | grep hoster-ddns
```

---

## Как это работает

1. Аутентификация в API hoster.by по Access-Key / Secret-Key → JWT-токен
2. Токен и ORDER_ID кэшируются в `/tmp/hoster_ddns_<root_domain>.tok` до истечения срока
3. Поиск DNS-ордера для корневого домена (или берётся из `ORDER_ID_OVERRIDE` / `param_opt`)
4. Чтение текущей A-записи
5. Если IP изменился — обновление через PATCH

## Лицензия

GPL-2.0-only
