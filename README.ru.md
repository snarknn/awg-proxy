# AWG Proxy (Portable Alpine)

English version: [README.md](README.md)

Контейнеризованный VPN-шлюз, который поднимает туннель AmneziaWG и предоставляет SOCKS5-прокси.

Поток трафика:
- Клиент -> SOCKS5-прокси (`microsocks`)
- Процесс прокси -> сетевой стек контейнера
- Политика маршрутизации контейнера -> AWG-туннель (`awg-quick` + userspace fallback через `amneziawg-go`)

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
- Конфиг AWG-клиента, смонтированный в `/config/amnezia.conf`

## Быстрый старт

1. Поместите ваш AWG-конфиг в `amnezia.conf` в корне проекта.
2. Запустите сервис:

```powershell
docker compose up --build -d
```

3. Проверьте статус:

```powershell
docker compose ps
docker compose logs --tail=120 awg-proxy
```

4. Используйте SOCKS5-прокси на хосте:

- Адрес: `127.0.0.1`
- Порт: `1080` (по умолчанию)

Пример:

```powershell
curl.exe --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

## Конфигурация

Compose публикует настраиваемый порт:

- `PROXY_PORT` (по умолчанию `1080`)

Поддерживаемые переменные окружения:

- `AWG_CONFIG_FILE` (по умолчанию `/config/amnezia.conf`)
- `WG_QUICK_USERSPACE_IMPLEMENTATION` (по умолчанию `amneziawg-go`)
- `LOG_LEVEL` (по умолчанию `info`)
- `WATCHDOG_INTERVAL` (по умолчанию `30`, интервал проверки AWG в секундах)
- `WATCHDOG_STALE_THRESHOLD` (по умолчанию `180`, перезапуск туннеля при устаревшем handshake)
- `WATCHDOG_LOG_EVERY` (по умолчанию `2`, вывод health-лога watchdog каждые N проверок)
- `PROXY_LISTEN_HOST` (по умолчанию `0.0.0.0`)
- `PROXY_PORT` (по умолчанию `1080`)
- `PROXY_USER`, `PROXY_PASSWORD` (опциональная авторизация, должны быть заданы вместе)
- `MICROSOCKS_BIND_ADDRESS` (опционально)
- `MICROSOCKS_WHITELIST` (опционально)
- `MICROSOCKS_AUTH_ONCE` (`0` или `1`)
- `MICROSOCKS_QUIET` (`0` или `1`)
- `MICROSOCKS_OPTS` (дополнительные флаги)

Поведение DNS:

- `DNS = ...` из AWG-конфига применяется к резолверу контейнера.
- Для переносимости используются два слоя:
  - `resolvconf` shim для DNS-хука в `awg-quick`.
  - Явное применение DNS в `entrypoint.sh` после `awg-quick up`.
- В Docker Desktop запуск AWG может занимать время (retry endpoint это нормально), поэтому проверяйте DNS после завершения стартовых логов.

## Примечания по AWG-конфигу

- Имя файла должно оканчиваться на `.conf`.
- В `AllowedIPs` должны быть маршруты по умолчанию, если хотите отправлять весь прокси-трафик через VPN:
  - `0.0.0.0/0`
  - `::/0`
- Пустые присваивания, например `I2 =`, очищаются во время запуска в `entrypoint.sh` и пишутся во временный конфиг.

## Поведение на разных платформах

- Windows Docker Desktop: ожидается userspace fallback через `amneziawg-go`.
- Linux с установленным kernel-модулем: `awg-quick` может сначала использовать kernel-путь.

## Как проверить, что контейнер работает

1. Проверьте, что сервис запущен:

```powershell
docker compose ps
```

Ожидаемо: сервис `awg-proxy` в состоянии `Up`, порт прокси опубликован.

2. Проверьте логи запуска:

```powershell
docker compose logs --tail=120 awg-proxy
```

Ожидаемо: строки о поднятии AWG и запуске `microsocks`.

3. Проверьте выход в сеть через прокси с помощью curl:

```powershell
curl.exe --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

Если у вас нестандартный порт прокси, замените `1080` на значение `PROXY_PORT`.

4. Дополнительно проверьте состояние туннеля внутри контейнера:

```powershell
docker exec awg-proxy awg show
```

5. Проверьте, что DNS из AWG-конфига применился внутри контейнера:

```powershell
docker exec awg-proxy cat /etc/resolv.conf
docker exec awg-proxy nslookup google.com
```

Ожидаемо: в `resolv.conf` будут `nameserver` из AWG-конфига (например, `1.1.1.1`), а `nslookup` покажет один из этих серверов.

Если прямой и проксированный внешний IP совпадают, возможно хост уже использует тот же upstream-маршрут. В таком случае ориентируйтесь на счетчики `awg show` и логи контейнера.

## Устранение проблем

- `/dev/net/tun is missing`
  - Убедитесь, что в compose есть `devices: - /dev/net/tun:/dev/net/tun`.

- `Line unrecognized: I2=`
  - Исправлено runtime-очисткой в `entrypoint.sh`. Используйте текущий образ.

- `sysctl: permission denied on key net.ipv4.conf.all.src_valid_mark`
  - Ожидаемо в некоторых окружениях Docker Desktop.
  - Текущий образ это допускает и продолжает запуск.

- Порт прокси занят
  - Переопределите host/container порт через `PROXY_PORT`.

- Прокси перестает работать после сна ноутбука или смены сети/локации
  - Держите `PersistentKeepalive = 25` в секции `Peer` AWG-конфига.
  - В текущем образе включен watchdog AWG: он проверяет `latest-handshakes` и перезапускает туннель, если handshake устарел.
  - При необходимости настройте `WATCHDOG_INTERVAL` и `WATCHDOG_STALE_THRESHOLD` через compose.

- В контейнере все еще `nameserver 127.0.0.11`
  - Дождитесь завершения запуска AWG (`docker compose logs --tail=120 awg-proxy`).
  - Повторно проверьте `docker exec awg-proxy cat /etc/resolv.conf`.
  - При необходимости перезапустите контейнер и подождите дольше (AWG может ретраить endpoint перед завершением настройки).

## Файлы

- `Dockerfile` - multi-stage сборка portable-образа на Alpine
- `entrypoint.sh` - запуск AWG и оркестрация прокси
- `docker-compose.yml` - capabilities, проброс tun, переменные окружения по умолчанию