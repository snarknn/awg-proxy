# AWG Proxy (Portable Alpine)

> **⚠️ Изменение, ломающее обратную совместимость (v2):** Формат конфигурации изменился.
> Все прикладные настройки (DNS, авторизация, watchdog, прокси) теперь находятся в `config/config.yml`
> в секции `global:` вместо переменных окружения в `docker-compose.yml`.
> Смотрите [Быстрый старт](#быстрый-старт) и [Конфигурация](#конфигурация).

English version: [README.md](README.md)

Контейнеризованный VPN-шлюз, который поднимает **несколько туннелей AmneziaWG** и предоставляет каждый как отдельный SOCKS5-прокси на собственном порту.

Поток трафика:
- Клиент -> SOCKS5-прокси (`microsocks`, привязан к IP AWG-интерфейса)
- Ядро, source-based маршрутизация -> соответствующий AWG-туннель (`awg-quick` + fallback на `amneziawg-go`)
- Каждый туннель имеет собственную таблицу маршрутизации для полной изоляции трафика

Проект рассчитан на работу в Windows Docker Desktop и Linux.

## Что входит в состав

- Базовый образ: Alpine (portable-вариант)
- Userspace-бэкенд AWG: `amneziawg-go`
- Инструменты AWG: `awg`, `awg-quick`
- Прокси: `microsocks`
- Оркестрация запуска: `entrypoint.sh`

## Требования

- Docker Engine / Docker Desktop
- Docker Compose v2
- Возможность `NET_ADMIN`
- Проброс устройства `/dev/net/tun`
- Конфиги AWG-клиента в каталоге `config/`

## Архитектура

```
Контейнер (single namespace)
┌──────────────────────────────────────────────────────┐
│  awg0 (us-east)  ← 10.8.1.2                         │
│  awg1 (eu-west)  ← 10.8.1.7                         │
│                                                      │
│  ip rule: from 10.8.1.2 → table 100 → dev awg0      │
│  ip rule: from 10.8.1.7 → table 101 → dev awg1      │
│                                                      │
│  microsocks -b 10.8.1.2 -p 1080  (→ awg0)           │
│  microsocks -b 10.8.1.7 -p 1081  (→ awg1)           │
│                                                      │
│  /etc/resolv.conf: объединённый DNS (или dns_override)│
│  watchdog x N (для каждого интерфейса)               │
└──────────────────────────────────────────────────────┘
```

Каждый экземпляр microsocks привязывает исходящие соединения к IP AWG-интерфейса через флаг `-b`. Ядро маршрутизирует трафик через нужный туннель с помощью правил source-based маршрутизации.

## Быстрый старт

1. Скопируйте примеры конфигов и отредактируйте реальными данными:

```powershell
cp config/amnezia.conf.example config/my-server.conf
cp config/config.yml.example config/config.yml
```

2. Отредактируйте `config/config.yml` — определите туннели и глобальные настройки:

```yaml
global:
  # log_level: info
  # proxy_listen_host: 0.0.0.0
  # proxy_user: myuser
  # proxy_password: changeme
  # dns_override: "1.1.1.1 8.8.8.8"

tunnels:
  - name: my-server
    port: 1080
```

3. Запустите сервис:

```powershell
docker compose up --build -d
```

4. Проверьте статус:

```powershell
docker compose ps
docker compose logs --tail=120 awg-proxy
```

5. Используйте SOCKS5-прокси на хосте — каждый порт маршрутирует через свой VPN-туннель:

```powershell
curl.exe --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
curl.exe --socks5-hostname 127.0.0.1:1081 https://api.ipify.org
```

## Конфигурация

### Каталог конфигов

Поместите `.conf` файлы AWG в каталог `config/`. Каждый конфиг должен содержать:

- Стандартные секции AWG `[Interface]` и `[Peer]`
- Стандартные поля AWG (`Address`, `PrivateKey`, `PublicKey` и т.д.)

### Манифест туннелей (`config/config.yml`)

`config/config.yml` — **единственный источник правды** для всей конфигурации. Разместите его в каталоге `config/` (монтируется в контейнер автоматически).

```yaml
global:
  # log_level: info
  # proxy_listen_host: 0.0.0.0
  # proxy_user: myuser
  # proxy_password: changeme
  # dns_override: "1.1.1.1 8.8.8.8"
  # whitelist: 192.168.0.0/16
  # watchdog_interval: 30
  # watchdog_stale_threshold: 180
  # watchdog_log_every: 2

tunnels:
  - name: us-east
    port: 1080

  - name: eu-west
    port: 1081
    config: eu-west.conf

  - name: asia-tokyo
    port: 1082
    config: tokyo.conf
```

#### Глобальные настройки

| Поле | По умолчанию | Описание |
|------|-------------|----------|
| `log_level` | `info` | Уровень логирования (`debug`, `info`, `warn`, `error`) |
| `dns_override` | *(пусто)* | DNS серверы через пробел, переопределяет DNS из всех конфигов |
| `proxy_listen_host` | `0.0.0.0` | Адрес привязки microsocks |
| `proxy_user` | *(пусто)* | Имя пользователя SOCKS5 (требует `proxy_password`) |
| `proxy_password` | *(пусто)* | Пароль SOCKS5 (требует `proxy_user`) |
| `whitelist` | *(пусто)* | CIDR whitelist для microsocks |
| `watchdog_interval` | `30` | Интервал проверки здоровья AWG в секундах |
| `watchdog_stale_threshold` | `180` | Перезапуск туннеля при устаревшем handshake |
| `watchdog_log_every` | `2` | Вывод health-лога watchdog каждые N проверок |

#### Поля туннеля

| Поле | Обязательно | Описание |
|------|-------------|----------|
| `name` | ✅ | Идентификатор туннеля (имя интерфейса, логи, маршрутизация) |
| `port` | ✅ | SOCKS5 порт для этого туннеля |
| `config` | ❌ | Имя `.conf` файла в `config/`. Если не указано — `<name>.conf` |

**Резолвинг конфига:**

- `config` не указан → ищет `config/<name>.conf`
- `config: eu-vpn.conf` (с `.conf`) → точное имя файла `config/eu-vpn.conf`
- `config: eu-vpn` (без `.conf`) → пробует `config/eu-vpn`, затем `config/eu-vpn.conf`

Пример структуры:
```
repo/
├── config/
│   ├── config.yml        # определения туннелей + глобальные настройки
│   ├── my-server.conf    # конфиг AWG (как от провайдера)
│   ├── eu-vpn.conf       # конфиг AWG
│   └── tokyo.conf        # конфиг AWG
```

### Переменные окружения

В `docker-compose.yml` остаются только настройки Docker/инфраструктуры:

- `WG_QUICK_USERSPACE_IMPLEMENTATION` (по умолчанию `amneziawg-go`) — userspace-бэкенд

Все прикладные настройки задаются через `config/config.yml` (см. [Глобальные настройки](#глобальные-настройки) выше).

### Поведение DNS

- Все уникальные записи `DNS` из всех конфигов объединяются в `/etc/resolv.conf`.
- Установите `dns_override` в секции `global:` файла `config/config.yml` для переопределения DNS серверов.
- Для изоляции DNS по туннелям см. раздел «Устранение проблем».

### Маппинг портов

Опубликуйте диапазон портов в `docker-compose.yml`. Точные порты задаются в `config/config.yml`:

```yaml
ports:
  # Диапазон портов для SOCKS5 туннелей. Точные порты задаются в config/config.yml.
  # ВАЖНО: порты в config/config.yml должны попадать в этот диапазон,
  # но контейнер не может проверить это автоматически.
  - "127.0.0.1:1080-1099:1080-1099/tcp"
```

> **⚠️ Ограничение:** Контейнер не может видеть какие порты промаплены на хосте.
> Если порт в `config/config.yml` не попадает в диапазон из `docker-compose.yml`,
> прокси запустится, но будет недоступен с хоста.

## Примечания по AWG-конфигу

- Имя файла должно оканчиваться на `.conf` и находиться в каталоге `config/`.
- В `AllowedIPs` должны быть маршруты по умолчанию, если хотите отправлять весь прокси-трафик через VPN:
  - `0.0.0.0/0`
  - `::/0`
- Пустые присваивания, например `I2 =`, очищаются во время запуска в `entrypoint.sh` и пишутся во временный конфиг.
- Имена туннелей, порты и привязки к конфигам определяются в `config/config.yml`, а не в конфигах AWG.

## Поведение на разных платформах

- Windows Docker Desktop: ожидается userspace fallback через `amneziawg-go`.
- Linux с установленным kernel-модулем: `awg-quick` может сначала использовать kernel-путь.

## Как проверить, что контейнер работает

1. Проверьте, что сервис запущен:

```powershell
docker compose ps
```

Ожидаемо: сервис `awg-proxy` в состоянии `Up`, порты прокси опубликованы.

2. Проверьте логи запуска:

```powershell
docker compose logs --tail=120 awg-proxy
```

Ожидаемо: строки о обнаруженных туннелях, поднятии AWG-интерфейсов, source-based маршрутизации и запуске `microsocks`.

3. Проверьте правила source-based маршрутизации:

```powershell
docker exec awg-proxy ip rule show
```

Ожидаемо: правила для каждого IP туннеля, маппящих на свою таблицу маршрутизации.

4. Проверьте таблицы маршрутизации:

```powershell
docker exec awg-proxy ip route show table 100
```

Ожидаемо: `default dev awg0` (или подобное).

5. Проверьте выход в сеть через прокси для каждого туннеля:

```powershell
curl.exe --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
curl.exe --socks5-hostname 127.0.0.1:1081 https://api.ipify.org
```

Каждый должен вернуть разный внешний IP (выходной IP соответствующего VPN).

6. Дополнительно проверьте состояние туннеля внутри контейнера:

```powershell
docker exec awg-proxy awg show
```

7. Проверьте DNS:

```powershell
docker exec awg-proxy cat /etc/resolv.conf
docker exec awg-proxy nslookup google.com
```

Ожидаемо: в `resolv.conf` будут все уникальные `nameserver` из ваших конфигов.

Если прямой и проксированный внешний IP совпадают, возможно хост уже использует тот же upstream-маршрут. В таком случае ориентируйтесь на счетчики `awg show` и логи контейнера.

## Устранение проблем

- `/dev/net/tun is missing`
  - Убедитесь, что в compose есть `devices: - /dev/net/tun:/dev/net/tun`.

- `Line unrecognized: I2=`
  - Исправлено runtime-очисткой в `entrypoint.sh`. Используйте текущий образ.

- `sysctl: permission denied on key net.ipv4.conf.all.src_valid_mark`
  - Ожидаемо в некоторых окружениях Docker Desktop.
  - Текущий образ это допускает и продолжает запуск.

- `tunnels manifest not found`
  - Убедитесь, что `config/config.yml` существует в каталоге `config/` и примонтирован в контейнер.

- `config not found for tunnel 'X'`
  - `.conf` файл, указанный (или подразумеваемый по `name`) в `config/config.yml`, не найден в `config/`.

- Ошибка дублирования порта
  - Каждый туннель должен использовать уникальный порт в `config/config.yml`.

- Порт прокси недоступен с хоста
  - Убедитесь, что порт из `config/config.yml` попадает в диапазон, опубликованный в `docker-compose.yml`.
  - Контейнер не может проверить это — это ручная проверка.

- Прокси перестает работать после сна ноутбука или смены сети/локации
  - Держите `PersistentKeepalive = 25` в секции `Peer` AWG-конфига.
  - В текущем образе включен watchdog для каждого туннеля: он проверяет `latest-handshakes` и перезапускает туннель, если handshake устарел.
  - При необходимости настройте `watchdog_interval` и `watchdog_stale_threshold` в `config/config.yml`.

- В контейнере все еще `nameserver 127.0.0.11`
  - Дождитесь завершения запуска AWG (`docker compose logs --tail=120 awg-proxy`).
  - Повторно проверьте `docker exec awg-proxy cat /etc/resolv.conf`.
  - При необходимости перезапустите контейнер и подождите дольше (AWG может ретраить endpoint перед завершением настройки).

- Нужна изоляция DNS по туннелям
  - По умолчанию используется объединённый DNS для всех туннелей.
  - Установите `dns_override` в секции `global:` файла `config/config.yml` для глобального переопределения DNS серверов.
  - Для полной изоляции DNS используйте network namespaces (нужна的能力 `SYS_ADMIN`).

## Файлы

- `Dockerfile` - multi-stage сборка portable-образа на Alpine (с `yq` для парсинга YAML)
- `entrypoint.sh` - запуск нескольких AWG-туннелей и оркестрация прокси
- `docker-compose.yml` - capabilities, проброс tun, диапазон портов, volume mounts
- `config/config.yml` - определения туннелей + глобальные настройки (gitignored)
- `config/config.yml.example` - пример манифеста с вымышленными данными (безопасно для коммита)
- `config/` - конфиги AWG `.conf` (gitignored, реальные ключи остаются локально)
- `amnezia.conf.example` - шаблон конфига AWG (безопасно для коммита)