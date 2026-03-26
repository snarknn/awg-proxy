#!/usr/bin/env bash

set -Eeuo pipefail

AWG_CONFIG_FILE="${AWG_CONFIG_FILE:-/config/amnezia.conf}"
WG_QUICK_USERSPACE_IMPLEMENTATION="${WG_QUICK_USERSPACE_IMPLEMENTATION:-amneziawg-go}"
LOG_LEVEL="${LOG_LEVEL:-info}"
PROXY_LISTEN_HOST="${PROXY_LISTEN_HOST:-0.0.0.0}"
PROXY_PORT="${PROXY_PORT:-1080}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}"
WATCHDOG_STALE_THRESHOLD="${WATCHDOG_STALE_THRESHOLD:-180}"
WATCHDOG_LOG_EVERY="${WATCHDOG_LOG_EVERY:-2}"
PROXY_USER="${PROXY_USER:-}"
PROXY_PASSWORD="${PROXY_PASSWORD:-}"
MICROSOCKS_BIND_ADDRESS="${MICROSOCKS_BIND_ADDRESS:-}"
MICROSOCKS_WHITELIST="${MICROSOCKS_WHITELIST:-}"
MICROSOCKS_AUTH_ONCE="${MICROSOCKS_AUTH_ONCE:-0}"
MICROSOCKS_QUIET="${MICROSOCKS_QUIET:-0}"
MICROSOCKS_OPTS="${MICROSOCKS_OPTS:-}"

interface_name=""
proxy_pid=""
watchdog_pid=""
runtime_awg_config=""

prepare_runtime_config() {
    runtime_awg_config="/tmp/${interface_name}.conf"

    awk '
        /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*$/ { next }
        { print }
    ' "$AWG_CONFIG_FILE" > "$runtime_awg_config"

    chmod 600 "$runtime_awg_config"
}

apply_dns() {
    local resolv_content
    resolv_content="$(awk -F'[=,]' '
        /^[[:space:]]*DNS[[:space:]]*=/ {
            for (i = 2; i <= NF; i++) {
                gsub(/[[:space:]]/, "", $i)
                if ($i == "") continue
                if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || $i ~ /:/)
                    print "nameserver " $i
                else
                    print "search " $i
            }
        }
    ' "$runtime_awg_config")"

    [[ -z "$resolv_content" ]] && return 0

    printf '%s\n' "$resolv_content" > /etc/resolv.conf
    echo "[+] Applied DNS from config to /etc/resolv.conf"
}

restart_tunnel() {
    echo "[watchdog] Restarting AmneziaWG interface: $interface_name"

    awg-quick down "$runtime_awg_config" >/dev/null 2>&1 || true
    sleep 2

    if awg-quick up "$runtime_awg_config"; then
        apply_dns
        echo "[watchdog] Tunnel restart completed"
        return 0
    fi

    echo "[watchdog] Failed to bring AWG back up" >&2
    return 1
}

watchdog_awg() {
    local check_count=0
    local started_at
    started_at="$(date +%s)"

    echo "[watchdog] Loop started for interface '$interface_name'"

    while true; do
        sleep "$WATCHDOG_INTERVAL"
        check_count=$(( check_count + 1 ))

        local handshake_ts
        if ! handshake_ts="$(awg show "$interface_name" latest-handshakes 2>/dev/null | awk '($2 + 0) > max { max = $2 + 0 } END { print max + 0 }')"; then
            echo "[watchdog] Failed to read latest-handshakes; attempting tunnel restart"
            restart_tunnel || true
            continue
        fi

        if [[ -z "$handshake_ts" || "$handshake_ts" -eq 0 ]]; then
            local now_no_hs no_hs_age
            now_no_hs="$(date +%s)"
            no_hs_age=$(( now_no_hs - started_at ))

            if (( check_count % WATCHDOG_LOG_EVERY == 0 )); then
                echo "[watchdog] No handshake yet (age=${no_hs_age}s, threshold=${WATCHDOG_STALE_THRESHOLD}s)"
            fi

            if (( no_hs_age > WATCHDOG_STALE_THRESHOLD )); then
                echo "[watchdog] No handshake for ${no_hs_age}s; restarting tunnel"
                restart_tunnel || true
                started_at="$(date +%s)"
            fi

            continue
        fi

        local now age
        now="$(date +%s)"
        age=$(( now - handshake_ts ))

        if (( age < 0 )); then
            echo "[watchdog] Skipping check due to negative handshake age (${age}s)"
            continue
        fi

        if (( check_count % WATCHDOG_LOG_EVERY == 0 )); then
            echo "[watchdog] Healthy check: latest handshake age=${age}s"
        fi

        if (( age > WATCHDOG_STALE_THRESHOLD )); then
            echo "[watchdog] Last handshake is stale (${age}s > ${WATCHDOG_STALE_THRESHOLD}s)"
            restart_tunnel || true
            started_at="$(date +%s)"
        fi
    done
}

cleanup() {
    local exit_code=$?

    trap - EXIT INT TERM

    if [[ -n "$proxy_pid" ]]; then
        kill "$proxy_pid" 2>/dev/null || true
        wait "$proxy_pid" 2>/dev/null || true
    fi

    if [[ -n "$watchdog_pid" ]]; then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi

    if [[ -n "$interface_name" ]]; then
        awg-quick down "$runtime_awg_config" >/dev/null 2>&1 || true
    fi

    if [[ -n "$runtime_awg_config" ]]; then
        rm -f "$runtime_awg_config"
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM

if [[ "$EUID" -ne 0 ]]; then
    echo "entrypoint.sh: container must run as root" >&2
    exit 1
fi

if [[ ! -f "$AWG_CONFIG_FILE" ]]; then
    echo "entrypoint.sh: missing AWG config at $AWG_CONFIG_FILE" >&2
    exit 1
fi

if [[ "${AWG_CONFIG_FILE##*.}" != "conf" ]]; then
    echo "entrypoint.sh: config file must end with .conf so awg-quick can derive the interface name" >&2
    exit 1
fi

if [[ ! -c /dev/net/tun ]]; then
    echo "entrypoint.sh: /dev/net/tun is missing; run the container with NET_ADMIN and map /dev/net/tun" >&2
    exit 1
fi

interface_name="$(basename "$AWG_CONFIG_FILE" .conf)"

export WG_QUICK_USERSPACE_IMPLEMENTATION
export LOG_LEVEL

if ! [[ "$WATCHDOG_INTERVAL" =~ ^[0-9]+$ ]] || (( WATCHDOG_INTERVAL < 1 )); then
    echo "entrypoint.sh: WATCHDOG_INTERVAL must be a positive integer" >&2
    exit 1
fi

if ! [[ "$WATCHDOG_STALE_THRESHOLD" =~ ^[0-9]+$ ]] || (( WATCHDOG_STALE_THRESHOLD < 1 )); then
    echo "entrypoint.sh: WATCHDOG_STALE_THRESHOLD must be a positive integer" >&2
    exit 1
fi

if ! [[ "$WATCHDOG_LOG_EVERY" =~ ^[0-9]+$ ]] || (( WATCHDOG_LOG_EVERY < 1 )); then
    echo "entrypoint.sh: WATCHDOG_LOG_EVERY must be a positive integer" >&2
    exit 1
fi

prepare_runtime_config

echo "[+] Bringing up AmneziaWG interface: $interface_name"
awg-quick up "$runtime_awg_config"

apply_dns

watchdog_awg &
watchdog_pid=$!
echo "[+] Watchdog enabled (interval=${WATCHDOG_INTERVAL}s, stale-threshold=${WATCHDOG_STALE_THRESHOLD}s)"
echo "[+] Watchdog logging cadence: every ${WATCHDOG_LOG_EVERY} checks"

echo "[+] Current interface state"
awg show "$interface_name" || true

if ! awg show "$interface_name" allowed-ips | grep -Eq '(^|[[:space:]])(0\.0\.0\.0/0|::/0)([[:space:]]|$)'; then
    echo "[!] AWG config does not contain a default route in AllowedIPs. Only listed subnets will use the tunnel." >&2
fi

proxy_args=( -i "$PROXY_LISTEN_HOST" -p "$PROXY_PORT" )

if [[ -n "$PROXY_USER" || -n "$PROXY_PASSWORD" ]]; then
    if [[ -z "$PROXY_USER" || -z "$PROXY_PASSWORD" ]]; then
        echo "entrypoint.sh: PROXY_USER and PROXY_PASSWORD must be set together" >&2
        exit 1
    fi

    proxy_args+=( -u "$PROXY_USER" -P "$PROXY_PASSWORD" )
fi

if [[ -n "$MICROSOCKS_BIND_ADDRESS" ]]; then
    proxy_args+=( -b "$MICROSOCKS_BIND_ADDRESS" )
fi

if [[ -n "$MICROSOCKS_WHITELIST" ]]; then
    proxy_args+=( -w "$MICROSOCKS_WHITELIST" )
fi

if [[ "$MICROSOCKS_AUTH_ONCE" == "1" ]]; then
    proxy_args+=( -1 )
fi

if [[ "$MICROSOCKS_QUIET" == "1" ]]; then
    proxy_args+=( -q )
fi

if [[ -n "$MICROSOCKS_OPTS" ]]; then
    read -r -a extra_proxy_args <<< "$MICROSOCKS_OPTS"
    proxy_args+=( "${extra_proxy_args[@]}" )
fi

echo "[+] Starting microsocks on ${PROXY_LISTEN_HOST}:${PROXY_PORT}"
microsocks "${proxy_args[@]}" &
proxy_pid=$!

wait "$proxy_pid"