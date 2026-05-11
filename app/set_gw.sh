#!/usr/bin/env bash

set -o pipefail

INTERFACE="bat0"

THRESHOLD_TQ=50
SLEEP_INTERVAL=5
MIN_IMPROVEMENT=15
SWITCH_COOLDOWN=30

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

trap 'exit 0' INT TERM

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
            echo "[$(date +%T)] Gateway aplied: $BEST_IP via $INTERFACE (TQ: $BEST_TQ)"
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