# AWG Proxy (Portable Alpine)

> **⚠️ Breaking change (v2):** Configuration format has changed.
> All application settings (DNS, auth, watchdog, proxy) now live in `config/config.yml`
> under the `global:` section instead of environment variables in `docker-compose.yml`.
> See [Quick start](#quick-start) and [Configuration](#configuration) for the new format.

Russian version: [README.ru.md](README.ru.md)

Containerized VPN gateway that establishes **multiple AmneziaWG tunnels** and exposes each as a separate SOCKS5 proxy on its own port.

Traffic flow:
- Client -> SOCKS5 proxy (`microsocks`, bound to AWG interface IP)
- Kernel source-based routing -> matching AWG tunnel (`awg-quick` + `amneziawg-go` userspace fallback)
- Each tunnel has its own routing table for complete traffic isolation

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
- AWG client configs placed in `config/` directory

## Architecture

```
Container (single namespace)
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
│  /etc/resolv.conf: union DNS (or dns_override)       │
│  watchdog x N (per interface)                        │
└──────────────────────────────────────────────────────┘
```

Each microsocks instance binds outgoing connections to its AWG interface IP via `-b`. The kernel routes traffic through the correct tunnel using source-based routing rules.

## Quick start

1. Copy the example files and edit with your real values:

```powershell
cp config/amnezia.conf.example config/my-server.conf
cp config/config.yml.example config/config.yml
```

2. Edit `config/config.yml` — define your tunnels and global settings:

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

3. Start service:

```powershell
docker compose up --build -d
```

4. Check status:

```powershell
docker compose ps
docker compose logs --tail=120 awg-proxy
```

5. Use SOCKS5 proxy on host - each port routes through its own VPN tunnel:

```powershell
curl.exe --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
curl.exe --socks5-hostname 127.0.0.1:1081 https://api.ipify.org
```

## Configuration

### Config directory

Place AWG `.conf` files in the `config/` directory. Each config must have:

- Standard AWG `[Interface]` and `[Peer]` sections
- Standard AWG fields (`Address`, `PrivateKey`, `PublicKey`, etc.)

### Tunnel manifest (`config/config.yml`)

`config/config.yml` is the **single source of truth** for all configuration. Place it in the `config/` directory (mounted into the container automatically).

```yaml
global:
  # log_level: info
  # proxy_listen_host: 0.0.0.0
  # proxy_user: myuser
  # proxy_password: changeme
  # dns_override: "1.1.1.1 8.8.8.8"
  # whitelist: 192.168.0.0/16
  watchdog_interval: 30
  watchdog_stale_threshold: 180
  watchdog_log_every: 2

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

#### Global settings

| Field | Default | Description |
|-------|---------|-------------|
| `log_level` | `info` | Logging level (`debug`, `info`, `warn`, `error`) |
| `dns_override` | *(empty)* | Space-separated DNS servers, overrides all config DNS |
| `dns_via_tunnel` | `true` | Route DNS queries through tunnels (anti-hijack). Set `false` to use plain DNS via default route (e.g. for LAN resolvers) |
| `proxy_listen_host` | `0.0.0.0` | microsocks bind address |
| `proxy_user` | *(empty)* | SOCKS5 auth username (requires `proxy_password`) |
| `proxy_password` | *(empty)* | SOCKS5 auth password (requires `proxy_user`) |
| `whitelist` | *(empty)* | CIDR whitelist for microsocks |
| `watchdog_interval` | `30` | Seconds between AWG health checks |
| `watchdog_stale_threshold` | `180` | Restart tunnel when handshake is older than this |
| `watchdog_log_every` | `2` | Log watchdog health every N-th check |

#### Tunnel fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | ✅ | Tunnel identifier (used for interface name, logging, routing) |
| `port` | ✅ | SOCKS5 port for this tunnel |
| `config` | ❌ | AWG config filename in `config/`. If omitted, uses `<name>.conf` |

**Config resolution:**

- `config` not set → looks for `config/<name>.conf`
- `config: eu-vpn.conf` (with `.conf`) → exact filename `config/eu-vpn.conf`
- `config: eu-vpn` (without `.conf`) → tries `config/eu-vpn`, then `config/eu-vpn.conf`

Example structure:
```
repo/
├── config/
│   ├── config.yml        # tunnel definitions + global settings
│   ├── my-server.conf    # AWG config (as received from provider)
│   ├── eu-vpn.conf       # AWG config
│   └── tokyo.conf        # AWG config
```

### Environment variables

Only Docker/infrastructure settings remain in `docker-compose.yml`:

- `WG_QUICK_USERSPACE_IMPLEMENTATION` (default `amneziawg-go`) — userspace backend

All application settings are configured via `config/config.yml` (see [Global settings](#global-settings) above).

### DNS behavior

- All unique `DNS` entries from all configs are merged into `/etc/resolv.conf` (union).
- Set `dns_override` in `config/config.yml` `global:` section to override with custom DNS servers.
- **DNS anti-hijack (enabled by default):** DNS queries from microsocks are policy-routed through the tunnels to prevent ISP/TSPU DNS poisoning. Each nameserver is assigned round-robin to a started tunnel with `ip rule add to <ns> lookup <table>` + iptables SNAT to the AWG interface IP.
- Set `dns_via_tunnel: false` in `global:` to disable this and let DNS leave via the default route (e.g. for LAN resolvers like Pi-hole/AdGuard).
- For per-tunnel DNS isolation, see the troubleshooting section.

### Port mapping

Publish a port range in `docker-compose.yml`. Exact ports are defined in `config/config.yml`:

```yaml
ports:
  # Range for tunnel SOCKS5 ports. Exact ports are set in config/config.yml.
  # IMPORTANT: ports in config/config.yml must fall within this range,
  # but the container cannot verify this automatically.
  - "127.0.0.1:1080-1099:1080-1099/tcp"
```

> **⚠️ Port range caveat:** The container cannot see which ports are mapped
> on the host side. If a port in `config/config.yml` falls outside the range in
> `docker-compose.yml`, the proxy will start but be unreachable from the host.
> Always ensure the range covers all ports defined in your `config/config.yml`.

## Notes about AWG config

- File name must end with `.conf` and must exist in the `config/` directory.
- `AllowedIPs` should include default routes if you want all proxy traffic to go through VPN:
  - `0.0.0.0/0`
  - `::/0`
- Empty assignments like `I2 =` are sanitized at runtime by `entrypoint.sh` into a temporary config.
- Tunnel names, ports, and config file mappings are defined in `config/config.yml`, not in the AWG configs themselves.

## Platform behavior

- Windows Docker Desktop: expected to use userspace fallback (`amneziawg-go`).
- Linux with kernel module installed: `awg-quick` may use kernel path first.

## How to verify the container works

1. Check that the service is running:

```powershell
docker compose ps
```

Expected: service `awg-proxy` is `Up` and proxy ports are published.

2. Check startup logs:

```powershell
docker compose logs --tail=120 awg-proxy
```

Expected: lines about discovered tunnels, bringing up AWG interfaces, source routing, and starting `microsocks`.

3. Check source-based routing rules:

```powershell
docker exec awg-proxy ip rule show
```

Expected: rules for each tunnel IP mapping to its routing table.

4. Check routing tables:

```powershell
docker exec awg-proxy ip route show table 100
```

Expected: `default dev awg0` (or similar).

5. Test proxy egress for each tunnel:

```powershell
curl.exe --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
curl.exe --socks5-hostname 127.0.0.1:1081 https://api.ipify.org
```

Each should return a different public IP (the exit IP of its respective VPN).

6. Optional tunnel evidence from inside container:

```powershell
docker exec awg-proxy awg show
```

7. Verify DNS:

```powershell
docker exec awg-proxy cat /etc/resolv.conf
docker exec awg-proxy nslookup google.com
```

Expected: `resolv.conf` contains union of all `nameserver` entries from your configs.

If direct and proxied public IP are identical, your host may already use the same upstream route. In this case, rely on `awg show` counters and container logs to confirm traffic through the tunnel.

## Troubleshooting

- `/dev/net/tun is missing`
  - Ensure `devices: - /dev/net/tun:/dev/net/tun` is present in compose.

- `Line unrecognized: I2=`
  - Fixed by runtime sanitization in `entrypoint.sh`. Use the current image.

- `sysctl: permission denied on key net.ipv4.conf.all.src_valid_mark`
  - Expected in some Docker Desktop environments.
  - Current image tolerates this and continues startup.

- `tunnels manifest not found`
  - Ensure `config/config.yml` exists in the `config/` directory and is mounted into the container.

- `config not found for tunnel 'X'`
  - The `.conf` file specified (or implied by `name`) in `config/config.yml` was not found in `config/`.

- Duplicate port error
  - Each tunnel must use a unique port in `config/config.yml`.

- **Duplicate internal IP (Amnezia default subnet 10.8.1.0/24)**
  - AmneziaWG installer always uses subnet `10.8.1.0/24` and assigns IPs sequentially (`.2`, `.3`, `.4`...).
  - If multiple servers use defaults, tunnels will have colliding internal IPs (e.g. two tunnels with `10.8.1.2`).
  - **Behavior:** The container detects this at startup, logs a warning, and **skips the later tunnel(s)** while starting the others.
  - **Fix:** On the server (Amnezia Web UI or CLI), change the peer's `AllowedIPs` to a free IP in the same subnet (e.g. `10.8.1.50/32`). In the client `.conf`, change `Address` to match (e.g. `Address = 10.8.1.50/24`). Restart the container.

- Proxy port unreachable from host
  - Ensure the port from `config/config.yml` falls within the range published in `docker-compose.yml`.
  - The container cannot validate this — it is a manual check.

- Proxy stops working after laptop sleep or network/location change
  - Keep `PersistentKeepalive = 25` in AWG peer config.
  - Current image runs a per-tunnel AWG watchdog that checks `latest-handshakes` and restarts the tunnel when stale.
  - Tune with `watchdog_interval` and `watchdog_stale_threshold` in `config/config.yml` if needed.

- Container still shows `nameserver 127.0.0.11`
  - Wait until AWG startup completes (`docker compose logs --tail=120 awg-proxy`).
  - Re-check `docker exec awg-proxy cat /etc/resolv.conf`.
  - If needed, restart and wait longer (AWG may retry endpoint before finishing setup).

- Per-tunnel DNS isolation needed
  - Default behavior uses union DNS for all tunnels.
  - Set `dns_override` in `config/config.yml` `global:` section to use custom DNS servers globally.
  - **DNS anti-hijack is enabled by default** (`dns_via_tunnel: true`). DNS queries are routed through tunnels to prevent poisoning.
  - Set `dns_via_tunnel: false` in `global:` to disable and use plain DNS via default route (e.g. for LAN resolvers like Pi-hole/AdGuard).
  - For full per-tunnel DNS isolation, use network namespaces (requires `SYS_ADMIN` capability).

## Files

- `Dockerfile` - multi-stage Alpine portable build (with `yq` for YAML parsing)
- `entrypoint.sh` - multi-tunnel AWG startup and proxy orchestration
- `docker-compose.yml` - capabilities, tun mapping, port range, volume mounts
- `config/config.yml` - tunnel definitions + global settings (gitignored)
- `config/config.yml.example` - example manifest with fictional data (safe to commit)
- `config/` - AWG `.conf` files (gitignored, real credentials stay local)
- `amnezia.conf.example` - example AWG config template (safe to commit)
