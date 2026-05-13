#!/usr/bin/env bash

set -o pipefail

INTERFACE="bat0"
UPLINK_INTERFACE="eth0"
THRESHOLD_TQ=50
SLEEP_INTERVAL=5
MIN_IMPROVEMENT=15
SWITCH_COOLDOWN=30
CONNECTIVITY_TARGETS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
MAX_ETH0_FAILURES=3
ETH0_FAILURES=0
CLEANUP_BAT0_DEFAULT_ON_LOCAL_GATEWAY=true
LAST_SWITCH_TIME=0

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: execute this script as root."
    exit 1
fi

if ! command -v batctl >/dev/null 2>&1; then
    echo "Erro: batctl not found."
    exit 1
fi

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "Erro: interface $INTERFACE not found."
    exit 1
fi

if ! ip link show "$UPLINK_INTERFACE" >/dev/null 2>&1; then
    echo "Warning: interface $UPLINK_INTERFACE not found. This node will not be treated as a local Internet gateway."
fi

trap 'exit 0' INT TERM

has_link_on_eth0() {
    ip link show "$UPLINK_INTERFACE" 2>/dev/null |
    grep -qE 'state UP|LOWER_UP'
}

has_ipv4_on_eth0() {
    ip -4 addr show dev "$UPLINK_INTERFACE" 2>/dev/null |
    grep -q 'inet '
}

has_default_route_via_eth0() {
    ip route show default 2>/dev/null |
    awk -v iface="$UPLINK_INTERFACE" '
        $1 == "default" {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && $(i + 1) == iface) {
                    found = 1
                }
            }
        }
        END { exit found ? 0 : 1 }
    '
}

has_route_to_target_via_eth0() {
    local target="$1"

    ip route get "$target" 2>/dev/null |
    awk -v iface="$UPLINK_INTERFACE" '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && $(i + 1) == iface) {
                    found = 1
                }
            }
        }
        END { exit found ? 0 : 1 }
    '
}

has_eth0_connectivity() {
    local target

    has_link_on_eth0 || return 1
    has_ipv4_on_eth0 || return 1

    for target in "${CONNECTIVITY_TARGETS[@]}"; do
        if has_route_to_target_via_eth0 "$target"; then
            if ping -I "$UPLINK_INTERFACE" -c 1 -W 2 "$target" >/dev/null 2>&1; then
                return 0
            fi
        fi
    done

    return 1
}

is_batman_gateway_server() {
    batctl gw_mode 2>/dev/null |
    grep -qiE 'server'
}

has_bat0_default_route() {
    ip route show default dev "$INTERFACE" 2>/dev/null |
    grep -q '^default'
}

cleanup_bat0_default_route() {
    if [ "$CLEANUP_BAT0_DEFAULT_ON_LOCAL_GATEWAY" = true ] && has_bat0_default_route; then
        if ip route del default dev "$INTERFACE" 2>/dev/null; then
            echo "[$(date +%T)] Removed default route via $INTERFACE because this node has valid local connectivity via $UPLINK_INTERFACE."
        fi
    fi
}

disable_invalid_batman_gateway() {
    if ! is_batman_gateway_server; then
        ETH0_FAILURES=0
        return 1
    fi

    if has_eth0_connectivity; then
        ETH0_FAILURES=0
        return 1
    fi

    ETH0_FAILURES=$((ETH0_FAILURES + 1))

    echo "[$(date +%T)] Warning: $UPLINK_INTERFACE connectivity check failed $ETH0_FAILURES/$MAX_ETH0_FAILURES."

    if [ "$ETH0_FAILURES" -lt "$MAX_ETH0_FAILURES" ]; then
        return 1
    fi

    if batctl gw_mode client; then
        echo "[$(date +%T)] Disabled BATMAN gateway mode after $MAX_ETH0_FAILURES consecutive failures via $UPLINK_INTERFACE."
    else
        echo "[$(date +%T)] Error: failed to disable BATMAN gateway mode."
    fi

    ETH0_FAILURES=0
    return 0
}

is_valid_local_gateway_node() {
    if has_eth0_connectivity; then
        return 0
    fi

    return 1
}

get_ip_for_mac() {
    local mac="$1"
    local dc_data="$2"
    local ip_addr=""

    ip_addr=$(
        awk -v mac="$mac" '
            tolower($0) ~ tolower(mac) {
                print $1
                exit
            }
        ' <<< "$dc_data"
    )

    if [ -z "$ip_addr" ]; then
        ip_addr=$(
            ip neigh show dev "$INTERFACE" 2>/dev/null |
            awk -v mac="$mac" '
                tolower($0) ~ tolower(mac) {
                    print $1
                    exit
                }
            '
        )
    fi

    if [[ "$ip_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip_addr"
    fi
}

get_client_mac_for_gateway() {
    local gw_mac="$1"
    local tg_data="$2"
    local client_mac=""

    client_mac=$(
        awk -v mac="$gw_mac" '
            tolower($0) ~ tolower(mac) &&
            $0 !~ /33:33/ &&
            $0 !~ /01:00/ {
                print $1
                exit
            }
        ' <<< "$tg_data"
    )

    if [ -n "$client_mac" ]; then
        echo "$client_mac"
    else
        echo "$gw_mac"
    fi
}

while true; do
    BEST_IP=""
    BEST_TQ=0
    CURRENT_TQ=0
    if disable_invalid_batman_gateway; then
        sleep "$SLEEP_INTERVAL"
        continue
    fi

    if is_valid_local_gateway_node; then
        cleanup_bat0_default_route
        sleep "$SLEEP_INTERVAL"
        continue
    fi
    
    GW_DATA=$(batctl gwl -H 2>/dev/null | tr -d '()*')
    DC_DATA=$(batctl dc 2>/dev/null | tr -d '*')
    TG_DATA=$(batctl tg -n 2>/dev/null | tr -d '*')

    if [ -z "$GW_DATA" ]; then
        sleep "$SLEEP_INTERVAL"
        continue
    fi

    current_gw=$(
        ip route show default dev "$INTERFACE" 2>/dev/null |
        awk '/^default/ {print $3; exit}'
    )

    while read -r line; do
        [ -z "$line" ] && continue

        gw_mac=$(awk '{print $1}' <<< "$line")
        tq=$(awk '{print $2}' <<< "$line")

        [[ "$gw_mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || continue
        [[ "$tq" =~ ^[0-9]+$ ]] || continue

        [ "$tq" -ge "$THRESHOLD_TQ" ] || continue

        client_mac=$(get_client_mac_for_gateway "$gw_mac" "$TG_DATA")
        gw_ip=$(get_ip_for_mac "$client_mac" "$DC_DATA")

        [ -n "$gw_ip" ] || continue

        if [ "$tq" -gt "$BEST_TQ" ]; then
            BEST_TQ="$tq"
            BEST_IP="$gw_ip"
        fi

        if [ -n "$current_gw" ] && [ "$gw_ip" = "$current_gw" ]; then
            CURRENT_TQ="$tq"
        fi

    done <<< "$GW_DATA"

    if [ -z "$BEST_IP" ]; then
        sleep "$SLEEP_INTERVAL"
        continue
    fi

    if [ -z "$current_gw" ]; then
        if ip route replace default via "$BEST_IP" dev "$INTERFACE"; then
            LAST_SWITCH_TIME=$(date +%s)
            echo "[$(date +%T)] Gateway applied: $BEST_IP via $INTERFACE (TQ: $BEST_TQ)"
        fi

        sleep "$SLEEP_INTERVAL"
        continue
    fi

    if [ "$current_gw" = "$BEST_IP" ]; then
        sleep "$SLEEP_INTERVAL"
        continue
    fi

    now=$(date +%s)
    elapsed=$((now - LAST_SWITCH_TIME))
    improvement=$((BEST_TQ - CURRENT_TQ))

    if [ "$elapsed" -lt "$SWITCH_COOLDOWN" ]; then
        sleep "$SLEEP_INTERVAL"
        continue
    fi

    if [ "$CURRENT_TQ" -gt 0 ] && [ "$improvement" -lt "$MIN_IMPROVEMENT" ]; then
        sleep "$SLEEP_INTERVAL"
        continue
    fi

    if ip route replace default via "$BEST_IP" dev "$INTERFACE"; then
        LAST_SWITCH_TIME="$now"
        echo "[$(date +%T)] Gateway changed: $current_gw -> $BEST_IP via $INTERFACE | Previous TQ: $CURRENT_TQ | New TQ: $BEST_TQ"
    fi

    sleep "$SLEEP_INTERVAL"
done