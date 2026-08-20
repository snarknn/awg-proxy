# AGENTS.md

## Project summary

This repository contains a portable Dockerized AWG gateway with **multi-tunnel SOCKS5 proxy**.

Main runtime path:
- `entrypoint.sh` reads `/config/config.yml` manifest for tunnel definitions (name → port → config) and global settings (DNS, auth, watchdog, proxy)
- `load_global_config()` reads the `global:` section from `config.yml` and overrides env-var defaults
- For each tunnel: resolves config file, creates sanitized runtime config, brings up AWG interface, sets up source-based routing, starts `microsocks` bound to the AWG interface IP
- DNS: union of all configs' DNS entries applied to `/etc/resolv.conf`, or `dns_override` in `config.yml` `global:` section
- If kernel AWG interface type is unavailable, `awg-quick` falls back to `amneziawg-go`
- Per-tunnel watchdog monitors handshake health and restarts stale tunnels

## Current architecture

- Runtime base: Alpine
- AWG userspace backend: `amneziawg-go` (required for Windows Docker Desktop portability)
- AWG tools: `awg`, `awg-quick`
- Proxy: `microsocks` (one instance per tunnel, bound to AWG interface IP via `-b`)
- Routing: source-based routing via `ip rule add from <IP> lookup <table>` + `ip route add default dev <iface> table <N>`
- Init process: `tini`

## Known design decisions

1. Keep portable mode first
- Do not remove `amneziawg-go` from default image.
- This is necessary to keep Windows/macOS Docker Desktop working.

2. Multi-tunnel support
- `config/config.yml` defines all tunnels (name → port → config) and global settings.
- Mounted into container at `/config/config.yml` via docker-compose volume.
- AWG config files (`.conf`) are in `config/` directory, mounted to `/config/`.
- Interface name comes from `name` field in `config.yml` (not from filename).
- Each microsocks binds outgoing connections to its AWG interface IP via `-b` flag.
- Source-based routing (`ip rule` + `ip route table`) ensures traffic isolation between tunnels.

3. Runtime config sanitization
- `entrypoint.sh` writes a temporary runtime config in `/tmp/<iface>.conf`.
- Empty assignments (for example `I2 =`) are removed before `awg setconf`.

4. DNS strategy
- All unique DNS entries from all configs are merged into `/etc/resolv.conf` (union).
- `dns_override` in `config.yml` `global:` section can override with custom DNS servers.
- Per-tunnel DNS isolation requires network namespaces (needs `SYS_ADMIN`).

5. Desktop sysctl tolerance
- `awg-quick` is patched in image so `src_valid_mark` sysctl failure does not crash startup.

## Operational defaults

- Config directory: `/config/` (mount `config/` from host)
- Proxy bind host: `0.0.0.0`
- Routing table IDs: 100, 101, 102, ... (one per tunnel, starting at 100)
- Watchdog: per-tunnel, checks `latest-handshakes`

## Verification checklist (quick)

1. Build and run:
- `docker compose up --build -d`

2. Container health:
- `docker compose ps`
- Status should be `Up` and all configured ports should be published.

3. Runtime logs:
- `docker compose logs --tail=120 awg-proxy`
- Expect tunnel map from `config.yml`, AWG startup lines per interface, source routing, and `Starting microsocks` per port.

4. Source routing verification:
- `docker exec awg-proxy ip rule show` → rules for each tunnel IP
- `docker exec awg-proxy ip route show table 100` → `default dev awg0`

5. DNS verification:
- `docker exec awg-proxy cat /etc/resolv.conf` → union of nameservers from configs
- `docker exec awg-proxy nslookup google.com`

6. Proxy smoke test (each port):
- `curl.exe --socks5-hostname 127.0.0.1:1080 https://api.ipify.org`
- `curl.exe --socks5-hostname 127.0.0.1:1081 https://api.ipify.org`
- Each should return a different public IP (exit IP of respective VPN).

7. Optional tunnel evidence:
- `docker exec awg-proxy awg show`

Note:
- On Docker Desktop, AWG setup may take ~10-15s because endpoint retry can occur before full startup. Verify DNS after startup logs settle.

## Guardrails for future agents

- Prefer minimal, incremental edits.
- Preserve portable behavior unless user explicitly asks for Linux-only profile.
- If introducing kernel-only optimization, implement as separate profile/target, not replacement.
- Re-run compose startup and logs checks after changing Dockerfile or entrypoint.
- `config.yml` is the single source of truth for port assignments. Do NOT put ports in AWG config files.
- Port numbers must be unique across all tunnels in `config.yml`.
- Ports in `config.yml` MUST fall within the range published in `docker-compose.yml` (container cannot verify this).
- Routing table IDs start at 100 and auto-increment per tunnel index.
- microsocks `-b` flag binds outgoing connections to AWG interface IP — this is critical for source-based routing to work.
- `yq` is installed in the container for YAML parsing of `config.yml`.
- `config/config.yml` is gitignored (real config). `config/config.yml.example` is safe to commit (fictional data).
- `config/` directory is gitignored (real credentials). `amnezia.conf.example` is safe to commit.
- All application settings (DNS, auth, watchdog, proxy) live in `config.yml` `global:` section, not in docker-compose environment.
