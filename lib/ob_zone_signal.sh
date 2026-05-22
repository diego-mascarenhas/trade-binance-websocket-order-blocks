#!/bin/bash
# Order-book zone: near support (LONG) vs near resistance (SHORT)

_ob_zone_bc_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 > b + 0) ? 0 : 1 }'
}

_ob_zone_bc_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 < b + 0) ? 0 : 1 }'
}

# Echo LONG | SHORT | NEUTRAL from price position between support/resistance walls
ob_zone_touch_signal() {
    local symbol="$1"
    local current_price="$2"
    local upper_pct="${3:-75}"
    local lower_pct="${4:-25}"

    if ! declare -f ob_get >/dev/null 2>&1; then
        echo "NEUTRAL"
        return 0
    fi

    local support resistance range pct
    support=$(ob_get SUPPORT "$symbol")
    resistance=$(ob_get RESISTANCE "$symbol")

    if [ -z "$current_price" ] || ! _ob_zone_bc_gt "$current_price" "0"; then
        echo "NEUTRAL"
        return 0
    fi
    if [ "$support" = "0" ] || [ "$resistance" = "0" ] \
        || [ "$support" = "null" ] || [ "$resistance" = "null" ]; then
        echo "NEUTRAL"
        return 0
    fi

    range=$(echo "$resistance - $support" | bc -l 2>/dev/null)
    if [ -z "$range" ] || ! _ob_zone_bc_gt "$range" "0"; then
        echo "NEUTRAL"
        return 0
    fi

    if declare -f bc_safe_div >/dev/null 2>&1; then
        pct=$(bc_safe_div "($current_price - $support) * 100" "$range")
    else
        pct=$(echo "scale=8; ($current_price - $support) * 100 / $range" | bc -l 2>/dev/null)
    fi

    if [ -n "$pct" ] && _ob_zone_bc_lt "$pct" "$lower_pct"; then
        echo "LONG"
    elif [ -n "$pct" ] && _ob_zone_bc_gt "$pct" "$upper_pct"; then
        echo "SHORT"
    else
        echo "NEUTRAL"
    fi
}
