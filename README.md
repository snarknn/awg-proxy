# AWG Proxy (Portable Alpine)

Russian version: [README.ru.md](README.ru.md)

Containerized VPN gateway that establishes an AmneziaWG tunnel and exposes a SOCKS5 proxy.

Traffic flow:
- Client -> SOCKS5 proxy (`microsocks`)
- Proxy process -> container network stack
- Container routing policy -> AWG tunnel (`awg-quick` + `amneziawg-go` userspace fallback)

This project is designed to work on Windows Docker Desktop and Linux.

## What is included

- Base image: Alpine (portable variant)
- AWG userspace backend: `amneziawg-go`
- AWG tooling: `awg`, `awg-quick`
- Proxy: `microsocks`
- Entrypoint orchestration: `entrypoint.sh`

## Requirements

- Docker Engine / Docker Desktop
- Docker Compose v2
- `NET_ADMIN` capability
- `/dev/net/tun` device mapping
- AWG client config mounted to `/config/amnezia.conf`

## Quick start

1. Put your AWG config into `amnezia.conf` in project root.
2. Start service:

```powershell
docker compose up --build -d
```

3. Check status:

```powershell
docker compose ps
docker compose logs --tail=120 awg-proxy
```

4. Use SOCKS5 proxy on host:

- Address: `127.0.0.1`
- Port: `1080` (default)

Example:

```powershell
curl.exe --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

## Configuration

Compose publishes a configurable port:

- `PROXY_PORT` (default `1080`)

Supported environment variables:

- `AWG_CONFIG_FILE` (default `/config/amnezia.conf`)
- `WG_QUICK_USERSPACE_IMPLEMENTATION` (default `amneziawg-go`)
- `LOG_LEVEL` (default `info`)
- `WATCHDOG_INTERVAL` (default `30`, seconds between AWG health checks)
- `WATCHDOG_STALE_THRESHOLD` (default `180`, restart tunnel when latest handshake is older)
- `PROXY_LISTEN_HOST` (default `0.0.0.0`)
- `PROXY_PORT` (default `1080`)
- `PROXY_USER`, `PROXY_PASSWORD` (optional auth, must be set together)
- `MICROSOCKS_BIND_ADDRESS` (optional)
- `MICROSOCKS_WHITELIST` (optional)
- `MICROSOCKS_AUTH_ONCE` (`0` or `1`)
- `MICROSOCKS_QUIET` (`0` or `1`)
- `MICROSOCKS_OPTS` (extra flags)

DNS behavior:

- `DNS = ...` from AWG config is applied to container resolver.
- Runtime uses two layers for portability:
  - `resolvconf` shim for `awg-quick` DNS hook.
  - Explicit DNS apply step in `entrypoint.sh` after `awg-quick up`.
- On Docker Desktop, AWG startup may take time (endpoint retries are normal), so check resolver state after startup logs finish.

## Notes about AWG config

- File name must end with `.conf`.
- `AllowedIPs` should include default routes if you want all proxy traffic to go through VPN:
  - `0.0.0.0/0`
  - `::/0`
- Empty assignments like `I2 =` are sanitized at runtime by `entrypoint.sh` into a temporary config.

## Platform behavior

- Windows Docker Desktop: expected to use userspace fallback (`amneziawg-go`).
- Linux with kernel module installed: `awg-quick` may use kernel path first.

## How to verify the container works

1. Check that the service is running:

```powershell
docker compose ps
```

Expected: service `awg-proxy` is `Up` and the proxy port is published.

2. Check startup logs:

```powershell
docker compose logs --tail=120 awg-proxy
```

Expected: lines about bringing up AWG and starting `microsocks`.

3. Test proxy egress with curl:

```powershell
curl.exe --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

If your proxy port is custom, replace `1080` with `PROXY_PORT` value.

4. Optional tunnel evidence from inside container:

```powershell
docker exec awg-proxy awg show
```

5. Verify DNS from AWG config is active inside container:

```powershell
docker exec awg-proxy cat /etc/resolv.conf
docker exec awg-proxy nslookup google.com
```

Expected: `resolv.conf` contains `nameserver` entries from your AWG config (for example `1.1.1.1`) and `nslookup` reports one of those servers.

If direct and proxied public IP are identical, your host may already use the same upstream route. In this case, rely on `awg show` counters and container logs to confirm traffic through the tunnel.

## Troubleshooting

- `/dev/net/tun is missing`
  - Ensure `devices: - /dev/net/tun:/dev/net/tun` is present in compose.

- `Line unrecognized: I2=`
  - Fixed by runtime sanitization in `entrypoint.sh`. Use the current image.

- `sysctl: permission denied on key net.ipv4.conf.all.src_valid_mark`
  - Expected in some Docker Desktop environments.
  - Current image tolerates this and continues startup.

- Proxy port busy
  - Override host/container port via `PROXY_PORT`.

- Proxy stops working after laptop sleep or network/location change
  - Keep `PersistentKeepalive = 25` in AWG peer config.
  - Current image runs an AWG watchdog that checks `latest-handshakes` and restarts the tunnel when stale.
  - Tune with `WATCHDOG_INTERVAL` and `WATCHDOG_STALE_THRESHOLD` in compose if needed.

- Container still shows `nameserver 127.0.0.11`
  - Wait until AWG startup completes (`docker compose logs --tail=120 awg-proxy`).
  - Re-check `docker exec awg-proxy cat /etc/resolv.conf`.
  - If needed, restart and wait longer (AWG may retry endpoint before finishing setup).

## Files

- `Dockerfile` - multi-stage Alpine portable build
- `entrypoint.sh` - AWG startup and proxy orchestration
- `docker-compose.yml` - capabilities, tun mapping, env defaults
