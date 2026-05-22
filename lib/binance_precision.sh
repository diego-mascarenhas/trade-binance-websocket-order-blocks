#!/bin/bash
# Binance Futures price/qty rounding (tickSize / stepSize) — bash 3.2+ safe (no declare -A)

# One number per line (hedge mode can return multiple positionAmt from jq)
_bn_sanitize_num() {
    echo "$1" | head -1 | tr -d '[:space:]'
}

# Safe float compares (avoid (( $(bc) )) syntax errors on macOS bash)
_bn_is_positive() {
    local v
    v=$(_bn_sanitize_num "$1")
    [ -z "$v" ] && return 1
    awk -v v="$v" 'BEGIN { exit (v + 0 > 0) ? 0 : 1 }'
}

_bn_cmp_gt() {
    local a b
    a=$(_bn_sanitize_num "$1")
    b=$(_bn_sanitize_num "$2")
    awk -v a="$a" -v b="$b" 'BEGIN { exit (a + 0 > b + 0) ? 0 : 1 }'
}

_bnp_var_name() {
    local field="$1"
    local sym="$2"
    sym=$(echo "$sym" | tr -cd 'A-Za-z0-9_')
    echo "BNP_${field}__${sym}"
}

_bnp_set() {
    local field="$1" sym="$2" val="$3"
    local vn
    vn=$(_bnp_var_name "$field" "$sym")
    printf -v "$vn" '%s' "$val"
}

_bnp_get() {
    local field="$1" sym="$2"
    local vn v
    vn=$(_bnp_var_name "$field" "$sym")
    v="${!vn}"
    echo "$v"
}

# Decimal places from tickSize/stepSize (0.0001 -> 4, 0.00010 -> 4, 0.1 -> 1)
_decimal_places_from_step() {
    local step="$1" norm frac
    norm=$(echo "$step" | sed -e 's/0*$//' -e 's/\.$//')
    if [[ "$norm" != *.* ]]; then
        echo 0
        return 0
    fi
    frac="${norm#*.}"
    # Must be integer for printf %.*f
    echo "${#frac}" | tr -cd '0-9'
}

# Round value to step/tick via bc (avoids awk float noise → Binance -1111)
_bn_format_to_step() {
    local value="$1"
    local step="$2"
    local mode="${3:-round}" # round | floor
    local dec n result

    value=$(_bn_sanitize_num "$value")
    step=$(_bn_sanitize_num "$step")

    if [ -z "$value" ] || [ "$value" = "0" ]; then
        echo "0"
        return 0
    fi
    if [ -z "$step" ] || ! _bn_is_positive "$step"; then
        echo "$value"
        return 0
    fi

    dec=$(_decimal_places_from_step "$step")
    case "$dec" in
        ''|*[!0-9]*) dec=8 ;;
    esac
    if [ "$mode" = "floor" ]; then
        n=$(echo "scale=0; $value / $step" | bc 2>/dev/null)
    else
        n=$(echo "scale=0; $value / $step + 0.5" | bc 2>/dev/null)
    fi
    n=${n%%.*}
    [ -z "$n" ] || [ "$n" -lt 1 ] 2>/dev/null && n=1
    result=$(echo "scale=${dec}; $n * $step / 1" | bc -l 2>/dev/null)
    if [ -z "$result" ]; then
        echo "$value"
        return 0
    fi
    if [ "$dec" -gt 0 ] 2>/dev/null; then
        LC_NUMERIC=C awk -v d="$dec" -v r="$result" 'BEGIN { printf "%.*f\n", d, r+0 }'
    else
        LC_NUMERIC=C printf "%.0f\n" "$result"
    fi
}

_round_to_tick() {
    _bn_format_to_step "$1" "$2" "round"
}

_round_to_step_floor() {
    _bn_format_to_step "$1" "$2" "floor"
}

load_symbol_precision() {
    local symbol="$1"
    local loaded
    loaded=$(_bnp_get LOADED "$symbol")
    [ -n "$loaded" ] && return 0
    init_all_symbol_precision "$symbol"
}

init_all_symbol_precision() {
    local symbols=("$@")
    local exchange symbol tick step mult_up mult_down
    exchange=$(curl -s "https://fapi.binance.com/fapi/v1/exchangeInfo" 2>/dev/null)
    [ -z "$exchange" ] && return 1

    for symbol in "${symbols[@]}"; do
        tick=$(echo "$exchange" | jq -r "
            .symbols[] | select(.symbol==\"$symbol\") |
            .filters[] | select(.filterType==\"PRICE_FILTER\") | .tickSize" 2>/dev/null | head -1)
        step=$(echo "$exchange" | jq -r "
            .symbols[] | select(.symbol==\"$symbol\") |
            .filters[] | select(.filterType==\"LOT_SIZE\") | .stepSize" 2>/dev/null | head -1)
        mult_up=$(echo "$exchange" | jq -r "
            .symbols[] | select(.symbol==\"$symbol\") |
            .filters[] | select(.filterType==\"PERCENT_PRICE\") | .multiplierUp" 2>/dev/null | head -1)
        mult_down=$(echo "$exchange" | jq -r "
            .symbols[] | select(.symbol==\"$symbol\") |
            .filters[] | select(.filterType==\"PERCENT_PRICE\") | .multiplierDown" 2>/dev/null | head -1)

        tick="${tick:-0.01}"
        step="${step:-0.001}"
        mult_up="${mult_up:-1.05}"
        mult_down="${mult_down:-0.95}"

        _bnp_set TICK "$symbol" "$tick"
        _bnp_set STEP "$symbol" "$step"
        _bnp_set MUP "$symbol" "$mult_up"
        _bnp_set MDOWN "$symbol" "$mult_down"
        _bnp_set LOADED "$symbol" "1"
    done
    return 0
}

round_price_for_symbol() {
    local symbol="$1"
    local price="$2"
    local tick
    [ -z "$price" ] || [ "$price" = "0" ] && echo "0" && return 0
    load_symbol_precision "$symbol"
    tick=$(_bnp_get TICK "$symbol")
    tick="${tick:-0.01}"
    _round_to_tick "$price" "$tick"
}

round_qty_for_symbol() {
    local symbol="$1"
    local qty="$2"
    local step
    [ -z "$qty" ] || [ "$qty" = "0" ] && echo "0" && return 0
    load_symbol_precision "$symbol"
    step=$(_bnp_get STEP "$symbol")
    step="${step:-0.001}"
    _round_to_step_floor "$qty" "$step"
}

get_futures_mark_price() {
    local symbol="$1"
    local mark
    mark=$(curl -s "https://fapi.binance.com/fapi/v1/premiumIndex?symbol=${symbol}" 2>/dev/null \
        | jq -r '.markPrice // empty' 2>/dev/null)
    echo "$mark"
}

clamp_limit_price_for_order() {
    local symbol="$1"
    local direction="$2"
    local price="$3"
    local mark="${4:-}"
    local tick mult_up mult_down raw

    [ -z "$price" ] || [ "$price" = "0" ] && echo "0" && return 0
    load_symbol_precision "$symbol"

    tick=$(_bnp_get TICK "$symbol")
    tick="${tick:-0.01}"
    mult_up=$(_bnp_get MUP "$symbol")
    mult_down=$(_bnp_get MDOWN "$symbol")
    mult_up="${mult_up:-1.05}"
    mult_down="${mult_down:-0.95}"

    if [ -z "$mark" ] || [ "$mark" = "null" ]; then
        mark=$(get_futures_mark_price "$symbol")
    fi
    if [ -z "$mark" ] || [ "$mark" = "null" ]; then
        round_price_for_symbol "$symbol" "$price"
        return 0
    fi

    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        LONG|BUY)
            p=$(_bn_sanitize_num "$price")
            m=$(_bn_sanitize_num "$mark")
            raw=$(awk -v p="$p" -v m="$m" -v u="$mult_up" 'BEGIN {
                maxp = m * u
                print (p > maxp) ? maxp : p
            }')
            ;;
        SHORT|SELL)
            p=$(_bn_sanitize_num "$price")
            m=$(_bn_sanitize_num "$mark")
            raw=$(awk -v p="$p" -v m="$m" -v d="$mult_down" 'BEGIN {
                minp = m * d
                print (p < minp) ? minp : p
            }')
            ;;
        *)
            raw="$price"
            ;;
    esac
    round_price_for_symbol "$symbol" "$raw"
}
