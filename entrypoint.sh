#!/usr/bin/env bash

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
WG_QUICK_USERSPACE_IMPLEMENTATION="${WG_QUICK_USERSPACE_IMPLEMENTATION:-amneziawg-go}"
LOG_LEVEL="${LOG_LEVEL:-info}"
PROXY_LISTEN_HOST="${PROXY_LISTEN_HOST:-0.0.0.0}"
DNS_OVERRIDE="${DNS_OVERRIDE:-}"
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
# Retry settings for AWG interface bring-up (mitigates amneziawg-go IPv6 init race)
AWG_UP_RETRIES="${AWG_UP_RETRIES:-3}"
AWG_UP_RETRY_DELAY="${AWG_UP_RETRY_DELAY:-2}"

CONFIG_DIR="${CONFIG_DIR:-/config}"

export WG_QUICK_USERSPACE_IMPLEMENTATION
export LOG_LEVEL

# ---------------------------------------------------------------------------
# Tracking arrays
# ---------------------------------------------------------------------------
declare -a TUNNEL_NAMES=()
declare -a TUNNEL_PORTS=()
declare -a TUNNEL_CONFIGS=()
declare -a TUNNEL_IPS=()
declare -a TUNNEL_TABLE_IDS=()
declare -a TUNNEL_MICROSOCKS_PIDS=()
declare -a TUNNEL_WATCHDOG_PIDS=()

# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

resolve_config() {
    local name="$1"
    local config_raw="${2:-}"

    if [[ -n "$config_raw" && "$config_raw" != "null" ]]; then
        # config field is set
        if [[ "$config_raw" == *.conf ]]; then
            # Exact filename with .conf extension
            if [[ -f "$CONFIG_DIR/$config_raw" ]]; then
                echo "$CONFIG_DIR/$config_raw"
                return 0
            fi
        else
            # Without .conf — try exact, then .conf suffix
            if [[ -f "$CONFIG_DIR/$config_raw" ]]; then
                echo "$CONFIG_DIR/$config_raw"
                return 0
            elif [[ -f "$CONFIG_DIR/${config_raw}.conf" ]]; then
                echo "$CONFIG_DIR/${config_raw}.conf"
                return 0
            fi
        fi
    else
        # No config field — use name.conf
        if [[ -f "$CONFIG_DIR/${name}.conf" ]]; then
            echo "$CONFIG_DIR/${name}.conf"
            return 0
        fi
    fi

    echo "entrypoint.sh: config not found for tunnel '$name' (looked in $CONFIG_DIR/)" >&2
    return 1
}

parse_interface_ip() {
    local config_file="$1"
    tr -d '\r' < "$config_file" | awk '
        /^\[/ { section = $0 }
        section ~ /^\[Interface\]/ && /^[[:space:]]*Address[[:space:]]*=/ {
            addr = $0
            sub(/^[[:space:]]*Address[[:space:]]*=[[:space:]]*/, "", addr)
            sub(/[[:space:]]*$/, "", addr)
            # Split on commas, take the first IPv4 (fallback to first entry),
            # and strip any CIDR mask so "ip rule from" gets a bare address.
            n = split(addr, parts, /,[[:space:]]*/)
            ip = ""
            for (i = 1; i <= n; i++) {
                p = parts[i]
                sub(/\/.*/, "", p)
                if (p ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { ip = p; break }
            }
            if (ip == "" && n > 0) { p = parts[1]; sub(/\/.*/, "", p); ip = p }
            print ip
            exit
        }
    '
}

parse_dns_from_config() {
    local config_file="$1"
    tr -d '\r' < "$config_file" | awk -F'[=,]' '
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
    '
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

TUNNELS_YAML="${TUNNELS_YAML:-/config/config.yml}"

# ---------------------------------------------------------------------------
# Global config from config.yml
# ---------------------------------------------------------------------------
# Reads the "global:" section and overrides env-var defaults.
# Env vars still work as fallback if global: is absent or incomplete.

load_global_config() {
    [[ ! -f "$TUNNELS_YAML" ]] && return 0

    local val

    val="$(yq '.global.log_level // ""' "$TUNNELS_YAML" 2>/dev/null)"
    [[ -n "$val" ]] && LOG_LEVEL="$val"

    val="$(yq '.global.dns_override // ""' "$TUNNELS_YAML" 2>/dev/null)"
    [[ -n "$val" ]] && DNS_OVERRIDE="$val"

    val="$(yq '.global.proxy_listen_host // ""' "$TUNNELS_YAML" 2>/dev/null)"
    [[ -n "$val" ]] && PROXY_LISTEN_HOST="$val"

    val="$(yq '.global.proxy_user // ""' "$TUNNELS_YAML" 2>/dev/null)"
    [[ -n "$val" ]] && PROXY_USER="$val"

    val="$(yq '.global.proxy_password // ""' "$TUNNELS_YAML" 2>/dev/null)"
    [[ -n "$val" ]] && PROXY_PASSWORD="$val"

    val="$(yq '.global.whitelist // ""' "$TUNNELS_YAML" 2>/dev/null)"
    [[ -n "$val" ]] && MICROSOCKS_WHITELIST="$val"

    val="$(yq '.global.watchdog_interval // ""' "$TUNNELS_YAML" 2>/dev/null)"
    [[ -n "$val" ]] && WATCHDOG_INTERVAL="$val"

    val="$(yq '.global.watchdog_stale_threshold // ""' "$TUNNELS_YAML" 2>/dev/null)"
    [[ -n "$val" ]] && WATCHDOG_STALE_THRESHOLD="$val"

    val="$(yq '.global.watchdog_log_every // ""' "$TUNNELS_YAML" 2>/dev/null)"
    [[ -n "$val" ]] && WATCHDOG_LOG_EVERY="$val"

    return 0
}

discover_tunnels() {
    if [[ ! -f "$TUNNELS_YAML" ]]; then
        echo "entrypoint.sh: tunnels manifest not found at $TUNNELS_YAML" >&2
        echo "  Create config/config.yml or set TUNNELS_YAML env var" >&2
        exit 1
    fi

    local tunnel_count
    tunnel_count="$(yq '.tunnels | length' "$TUNNELS_YAML" 2>/dev/null)" || {
        echo "entrypoint.sh: failed to parse $TUNNELS_YAML — is it valid YAML?" >&2
        exit 1
    }

    if (( tunnel_count == 0 )); then
        echo "entrypoint.sh: no tunnels defined in $TUNNELS_YAML" >&2
        exit 1
    fi

    echo "[+] Reading tunnel definitions from $TUNNELS_YAML ($tunnel_count tunnel(s))"

    local -a tmp_names=()
    local -a tmp_ports=()
    local -a tmp_ips=()
    local -a tmp_configs=()

    for (( i=0; i<tunnel_count; i++ )); do
        local name port config_raw config_resolved

        name="$(yq ".tunnels[$i].name" "$TUNNELS_YAML")"
        port="$(yq ".tunnels[$i].port" "$TUNNELS_YAML")"
        config_raw="$(yq ".tunnels[$i].config // \"\"" "$TUNNELS_YAML")"

        # Validate name
        if [[ -z "$name" || "$name" == "null" || "$name" == "" ]]; then
            echo "entrypoint.sh: tunnel[$i] is missing 'name' field in $TUNNELS_YAML" >&2
            exit 1
        fi

        # Validate port
        if [[ -z "$port" || "$port" == "null" || "$port" == "" ]]; then
            echo "entrypoint.sh: tunnel '$name' is missing 'port' field in $TUNNELS_YAML" >&2
            exit 1
        fi
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            echo "entrypoint.sh: invalid port '$port' for tunnel '$name' (must be 1-65535)" >&2
            exit 1
        fi

        # Resolve config file
        config_resolved="$(resolve_config "$name" "$config_raw")" || exit 1

        local ip
        ip="$(parse_interface_ip "$config_resolved")"
        if [[ -z "$ip" ]]; then
            echo "entrypoint.sh: cannot parse Address from $config_resolved" >&2
            exit 1
        fi

        tmp_names+=("$name")
        tmp_ports+=("$port")
        tmp_ips+=("$ip")
        tmp_configs+=("$config_resolved")
    done

    # Check for duplicate ports
    local -a seen_ports=()
    for port in "${tmp_ports[@]}"; do
        for sp in "${seen_ports[@]:-}"; do
            if [[ "$port" == "$sp" ]]; then
                echo "entrypoint.sh: duplicate port $port found in $TUNNELS_YAML" >&2
                exit 1
            fi
        done
        seen_ports+=("$port")
    done

    # Check for duplicate names
    local -a seen_names=()
    for name in "${tmp_names[@]}"; do
        for sn in "${seen_names[@]:-}"; do
            if [[ "$name" == "$sn" ]]; then
                echo "entrypoint.sh: duplicate tunnel name '$name' found in $TUNNELS_YAML" >&2
                exit 1
            fi
        done
        seen_names+=("$name")
    done

    for (( i=0; i<${#tmp_names[@]}; i++ )); do
        TUNNEL_NAMES+=("${tmp_names[$i]}")
        TUNNEL_PORTS+=("${tmp_ports[$i]}")
        TUNNEL_IPS+=("${tmp_ips[$i]}")
        TUNNEL_TABLE_IDS+=( $(( 100 + i )) )
        TUNNEL_CONFIGS+=("${tmp_configs[$i]}")
    done

    echo "[+] Tunnel map:"
    for (( i=0; i<${#TUNNEL_NAMES[@]}; i++ )); do
        echo "    ${TUNNEL_NAMES[$i]} → ${TUNNEL_CONFIGS[$i]##*/} → ${TUNNEL_IPS[$i]}:${TUNNEL_PORTS[$i]} (table ${TUNNEL_TABLE_IDS[$i]})"
    done
    echo "[+] ⚠️  Ensure all ports above are within the range published in docker-compose.yml"
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

apply_global_dns() {
    if [[ -n "$DNS_OVERRIDE" ]]; then
        local resolv_content=""
        for ns in $DNS_OVERRIDE; do
            ns="${ns#nameserver }"
            [[ -z "$resolv_content" ]] && resolv_content="nameserver ${ns}" || resolv_content="${resolv_content}"$'\n'"nameserver ${ns}"
        done
        printf '%s\n' "$resolv_content" > /etc/resolv.conf
        echo "[+] Applied DNS_OVERRIDE to /etc/resolv.conf: $DNS_OVERRIDE"
        return 0
    fi

    local -a all_nameservers=()
    local -a all_search=()

    for config_file in "${TUNNEL_CONFIGS[@]}"; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local type ns
            type="${line%% *}"
            ns="${line#* }"

            local found=0
            local -a check_list=()
            if [[ "$type" == "nameserver" ]]; then
                check_list=("${all_nameservers[@]:-}")
            elif [[ "$type" == "search" ]]; then
                check_list=("${all_search[@]:-}")
            else
                continue
            fi

            for existing in "${check_list[@]:-}"; do
                if [[ "$ns" == "$existing" ]]; then found=1; break; fi
            done

            if (( found == 0 )); then
                if [[ "$type" == "nameserver" ]]; then
                    all_nameservers+=("$ns")
                else
                    all_search+=("$ns")
                fi
            fi
        done < <(parse_dns_from_config "$config_file")
    done

    if (( ${#all_nameservers[@]} == 0 && ${#all_search[@]} == 0 )); then
        echo "[!] No DNS found in any config; keeping current /etc/resolv.conf" >&2
        return 0
    fi

    local resolv_content=""
    for ns in "${all_search[@]:-}"; do
        [[ -z "$ns" ]] && continue
        [[ -n "$resolv_content" ]] && resolv_content="${resolv_content}"$'\n'
        resolv_content="${resolv_content}search ${ns}"
    done
    for ns in "${all_nameservers[@]:-}"; do
        [[ -z "$ns" ]] && continue
        [[ -n "$resolv_content" ]] && resolv_content="${resolv_content}"$'\n'
        resolv_content="${resolv_content}nameserver ${ns}"
    done

    printf '%s\n' "$resolv_content" > /etc/resolv.conf
    echo "[+] Applied union DNS to /etc/resolv.conf (${#all_nameservers[@]} nameservers, ${#all_search[@]} search domains)"
}

# ---------------------------------------------------------------------------
# Runtime config preparation
# ---------------------------------------------------------------------------

prepare_runtime_config() {
    local source_config="$1"
    local target_config="$2"

    tr -d '\r' < "$source_config" | awk '
        /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*$/ { next }
        { print }
    ' > "$target_config"

    # Disable awg-quick's own routing policy. awg-quick adds a
    # "not fwmark X lookup X" rule (plus "suppress_prefixlength 0") for every
    # tunnel; with multiple tunnels those rules capture traffic from ANY
    # tunnel IP and misroute it into the wrong tunnel. Our source-based
    # routing (from <IP> lookup <table>) must be the sole routing policy.
    if grep -qi '^[[:space:]]*Table[[:space:]]*=' "$target_config"; then
        sed -i 's/^[[:space:]]*Table[[:space:]]*=.*/Table = off/' "$target_config"
    else
        sed -i '/^\[Interface\]/a Table = off' "$target_config"
    fi

    chmod 600 "$target_config"
}

# ---------------------------------------------------------------------------
# Source-based routing
# ---------------------------------------------------------------------------

setup_source_routing() {
    local iface="$1"
    local ip="$2"
    local table_id="$3"

    ip route replace default dev "$iface" table "$table_id"
    ip rule add from "$ip" lookup "$table_id" 2>/dev/null || true

    echo "[+] Source routing: from $ip → table $table_id → dev $iface"
}

remove_source_routing() {
    local ip="$1"
    local iface="$2"
    local table_id="$3"

    ip rule del from "$ip" lookup "$table_id" 2>/dev/null || true
    ip route del default dev "$iface" table "$table_id" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Microsocks helpers
# ---------------------------------------------------------------------------

build_microsocks_args() {
    local port="$1"
    local bind_ip="$2"

    local -a args=()
    args+=( -i "$PROXY_LISTEN_HOST" -p "$port" )

    # Outgoing bind (-b). microsocks accepts only ONE -b.
    # MICROSOCKS_BIND_ADDRESS overrides the per-tunnel AWG interface IP.
    if [[ -n "$MICROSOCKS_BIND_ADDRESS" ]]; then
        args+=( -b "$MICROSOCKS_BIND_ADDRESS" )
    elif [[ -n "$bind_ip" ]]; then
        args+=( -b "$bind_ip" )
    fi

    if [[ -n "$PROXY_USER" || -n "$PROXY_PASSWORD" ]]; then
        if [[ -z "$PROXY_USER" || -z "$PROXY_PASSWORD" ]]; then
            echo "entrypoint.sh: PROXY_USER and PROXY_PASSWORD must be set together" >&2
            exit 1
        fi
        args+=( -u "$PROXY_USER" -P "$PROXY_PASSWORD" )
    fi

    if [[ -n "$MICROSOCKS_WHITELIST" ]]; then
        args+=( -w "$MICROSOCKS_WHITELIST" )
    fi

    if [[ "$MICROSOCKS_AUTH_ONCE" == "1" ]]; then
        args+=( -1 )
    fi

    if [[ "$MICROSOCKS_QUIET" == "1" ]]; then
        args+=( -q )
    fi

    if [[ -n "$MICROSOCKS_OPTS" ]]; then
        read -r -a extra_args <<< "$MICROSOCKS_OPTS"
        args+=( "${extra_args[@]}" )
    fi

    # Emit all args on ONE line so the caller's `read -r -a` captures them all.
    printf '%s ' "${args[@]}"
}

# ---------------------------------------------------------------------------
# Watchdog (per-tunnel)
# ---------------------------------------------------------------------------

watchdog_awg() {
    local iface="$1"
    local table_id="$2"
    local config_file="$3"
    local check_count=0
    local started_at
    started_at="$(date +%s)"

    echo "[watchdog:${iface}] Loop started (table=${table_id})"

    while true; do
        sleep "$WATCHDOG_INTERVAL"
        check_count=$(( check_count + 1 ))

        local handshake_ts
        if ! handshake_ts="$(awg show "$iface" latest-handshakes 2>/dev/null | awk '($2 + 0) > max { max = $2 + 0 } END { print max + 0 }')"; then
            echo "[watchdog:${iface}] Failed to read latest-handshakes; attempting restart"
            do_restart_tunnel "$iface" "$config_file" "$table_id" || true
            continue
        fi

        if [[ -z "$handshake_ts" || "$handshake_ts" -eq 0 ]]; then
            local now_no_hs no_hs_age
            now_no_hs="$(date +%s)"
            no_hs_age=$(( now_no_hs - started_at ))

            if (( check_count % WATCHDOG_LOG_EVERY == 0 )); then
                echo "[watchdog:${iface}] No handshake yet (age=${no_hs_age}s, threshold=${WATCHDOG_STALE_THRESHOLD}s)"
            fi

            if (( no_hs_age > WATCHDOG_STALE_THRESHOLD )); then
                echo "[watchdog:${iface}] No handshake for ${no_hs_age}s; restarting"
                do_restart_tunnel "$iface" "$config_file" "$table_id" || true
                started_at="$(date +%s)"
            fi

            continue
        fi

        local now age
        now="$(date +%s)"
        age=$(( now - handshake_ts ))

        if (( age < 0 )); then
            echo "[watchdog:${iface}] Skipping check due to negative handshake age (${age}s)"
            continue
        fi

        if (( check_count % WATCHDOG_LOG_EVERY == 0 )); then
            echo "[watchdog:${iface}] Healthy: latest handshake age=${age}s"
        fi

        if (( age > WATCHDOG_STALE_THRESHOLD )); then
            echo "[watchdog:${iface}] Stale handshake (${age}s > ${WATCHDOG_STALE_THRESHOLD}s); restarting"
            do_restart_tunnel "$iface" "$config_file" "$table_id" || true
            started_at="$(date +%s)"
        fi
    done
}

do_restart_tunnel() {
    local iface="$1"
    local config_file="$2"
    local table_id="$3"
    local ip=""

    for (( i=0; i<${#TUNNEL_NAMES[@]}; i++ )); do
        if [[ "${TUNNEL_NAMES[$i]}" == "$iface" ]]; then
            ip="${TUNNEL_IPS[$i]}"
            break
        fi
    done

    echo "[watchdog:${iface}] Restarting AmneziaWG interface"

    local up_attempt
    local up_ok=0
    for (( up_attempt=1; up_attempt<=AWG_UP_RETRIES; up_attempt++ )); do
        awg-quick down "$config_file" >/dev/null 2>&1 || true
        sleep "$AWG_UP_RETRY_DELAY"
        if awg-quick up "$config_file"; then
            up_ok=1
            break
        fi
        echo "[watchdog:${iface}] awg-quick up attempt $up_attempt/$AWG_UP_RETRIES failed; retrying" >&2
    done

    if [[ "$up_ok" -eq 1 ]]; then
        if [[ -n "$ip" ]]; then
            setup_source_routing "$iface" "$ip" "$table_id"
        fi
        echo "[watchdog:${iface}] Restart completed"
        return 0
    fi

    echo "[watchdog:${iface}] Failed to bring AWG back up" >&2
    return 1
}

# ---------------------------------------------------------------------------
# Tunnel startup
# ---------------------------------------------------------------------------

start_tunnel() {
    local index="$1"
    local iface="${TUNNEL_NAMES[$index]}"
    local port="${TUNNEL_PORTS[$index]}"
    local ip="${TUNNEL_IPS[$index]}"
    local table_id="${TUNNEL_TABLE_IDS[$index]}"
    local source_config="${TUNNEL_CONFIGS[$index]}"
    local runtime_config="/tmp/${iface}.conf"

    echo ""
    echo "[+] ============================================"
    echo "[+] Starting tunnel: $iface (port=$port, ip=$ip, table=$table_id)"
    echo "[+] ============================================"

    prepare_runtime_config "$source_config" "$runtime_config"

    echo "[+] Validating config: $iface (awg-quick strip)"
    if ! awg-quick strip "$runtime_config" > /dev/null 2>&1; then
        echo "[!] Config validation failed for $iface — check PrivateKey, PublicKey, Endpoint" >&2
        return 1
    fi

    echo "[+] Bringing up AmneziaWG interface: $iface"
    local up_attempt
    local up_ok=0
    for (( up_attempt=1; up_attempt<=AWG_UP_RETRIES; up_attempt++ )); do
        if awg-quick up "$runtime_config"; then
            up_ok=1
            break
        fi
        echo "[!] awg-quick up attempt $up_attempt/$AWG_UP_RETRIES failed for $iface; retrying" >&2
        awg-quick down "$runtime_config" >/dev/null 2>&1 || true
        sleep "$AWG_UP_RETRY_DELAY"
    done
    if [[ "$up_ok" -ne 1 ]]; then
        echo "[!] Failed to bring up $iface after $AWG_UP_RETRIES attempts; skipping" >&2
        return 1
    fi

    setup_source_routing "$iface" "$ip" "$table_id"

    if ! awg show "$iface" allowed-ips 2>/dev/null | grep -Eq '(^|[[:space:]])(0\.0\.0\.0/0|::/0)([[:space:]]|$)'; then
        echo "[!] $iface: AWG config does not contain a default route in AllowedIPs. Only listed subnets will use the tunnel." >&2
    fi

    echo "[+] Current state of $iface:"
    awg show "$iface" || true

    local -a ms_args
    read -r -a ms_args < <(build_microsocks_args "$port" "$ip")
    echo "[+] Starting microsocks on ${PROXY_LISTEN_HOST}:${port} (bound to $ip)"
    microsocks "${ms_args[@]}" &
    TUNNEL_MICROSOCKS_PIDS+=( $! )

    watchdog_awg "$iface" "$table_id" "$runtime_config" &
    TUNNEL_WATCHDOG_PIDS+=( $! )
    echo "[+] Watchdog started for $iface (interval=${WATCHDOG_INTERVAL}s, stale-threshold=${WATCHDOG_STALE_THRESHOLD}s)"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM

    echo ""
    echo "[+] Cleaning up..."

    for pid in "${TUNNEL_WATCHDOG_PIDS[@]:-}"; do
        [[ -z "$pid" ]] && continue
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done

    for pid in "${TUNNEL_MICROSOCKS_PIDS[@]:-}"; do
        [[ -z "$pid" ]] && continue
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done

    for (( i=0; i<${#TUNNEL_NAMES[@]}; i++ )); do
        remove_source_routing "${TUNNEL_IPS[$i]}" "${TUNNEL_NAMES[$i]}" "${TUNNEL_TABLE_IDS[$i]}"
    done

    for (( i=0; i<${#TUNNEL_NAMES[@]}; i++ )); do
        local runtime_config="/tmp/${TUNNEL_NAMES[$i]}.conf"
        awg-quick down "$runtime_config" >/dev/null 2>&1 || true
        rm -f "$runtime_config"
    done

    echo "[+] Cleanup complete"
    exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

validate_env() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "entrypoint.sh: container must run as root" >&2
        exit 1
    fi

    if [[ ! -c /dev/net/tun ]]; then
        echo "entrypoint.sh: /dev/net/tun is missing; run the container with NET_ADMIN and map /dev/net/tun" >&2
        exit 1
    fi

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

    if [[ ! -d "$CONFIG_DIR" ]]; then
        echo "entrypoint.sh: config directory $CONFIG_DIR not found" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    load_global_config
    validate_env
    trap cleanup EXIT INT TERM

    discover_tunnels
    apply_global_dns

    local started=0
    for (( i=0; i<${#TUNNEL_NAMES[@]}; i++ )); do
        if start_tunnel "$i"; then
            started=$(( started + 1 ))
        fi
    done

    if (( started == 0 )); then
        echo "entrypoint.sh: no tunnels started successfully" >&2
        exit 1
    fi

    echo ""
    echo "[+] All tunnels started. Active: ${started}/${#TUNNEL_NAMES[@]}"
    echo "[+] Watching processes..."

    wait -n "${TUNNEL_MICROSOCKS_PIDS[@]}" 2>/dev/null || true
    echo "[!] A microsocks process exited" >&2
    exit 1
}

main