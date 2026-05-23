#!/bin/bash
# Futures wallet balance + per-symbol max leverage (Binance USDT-M)

_bwl_var_name() {
    local field="$1"
    local sym="$2"
    sym=$(echo "$sym" | tr -cd 'A-Za-z0-9_')
    echo "BWL_${field}__${sym}"
}

_bwl_set() {
    local field="$1" sym="$2" val="$3"
    local vn
    vn=$(_bwl_var_name "$field" "$sym")
    printf -v "$vn" '%s' "$val"
}

_bwl_get() {
    local field="$1" sym="$2"
    local vn v
    vn=$(_bwl_var_name "$field" "$sym")
    v="${!vn}"
    echo "$v"
}

_leverage_mode_is_max() {
    local mode="${LEVERAGE_MODE:-max}"
    mode=$(echo "$mode" | tr '[:upper:]' '[:lower:]')
    case "$mode" in
        max|maximum|true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

_position_size_uses_wallet_pct() {
    local pct="${POSITION_WALLET_PCT:-0}"
    local mode="${POSITION_SIZE_MODE:-}"
    mode=$(echo "$mode" | tr '[:upper:]' '[:lower:]')
    case "$mode" in
        wallet_pct|wallet|percent|pct) return 0 ;;
        fixed|fixed_usdt|usdt) return 1 ;;
    esac
    [ -n "$pct" ] && [ "$pct" != "0" ] && awk -v p="$pct" 'BEGIN { exit (p + 0 > 0) ? 0 : 1 }'
}

# Echo total USDT futures wallet balance (totalWalletBalance)
futures_get_wallet_balance_usdt() {
    local resp bal

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        echo ""
        return 1
    fi
    if ! declare -f _binance_fapi_signed_get >/dev/null 2>&1; then
        echo ""
        return 1
    fi

    resp=$(_binance_fapi_signed_get "/fapi/v2/account" "")
    bal=$(echo "$resp" | jq -r '.totalWalletBalance // empty' 2>/dev/null)
    if [ -z "$bal" ] || [ "$bal" = "null" ]; then
        resp=$(_binance_fapi_signed_get "/fapi/v2/balance" "")
        bal=$(echo "$resp" | jq -r '.[] | select(.asset=="USDT") | .balance' 2>/dev/null | head -1)
    fi
    if declare -f _bn_sanitize_num >/dev/null 2>&1; then
        bal=$(_bn_sanitize_num "$bal")
    fi
    if [ -z "$bal" ] || ! awk -v v="$bal" 'BEGIN { exit (v + 0 > 0) ? 0 : 1 }' 2>/dev/null; then
        echo ""
        return 1
    fi
    echo "$bal"
}

# Echo max initial leverage for symbol (cached per process)
futures_get_symbol_max_leverage() {
    local symbol="$1"
    local cached resp max_lev

    cached=$(_bwl_get MAX_LEV "$symbol")
    if [ -n "$cached" ] && [ "$cached" != "0" ]; then
        echo "$cached"
        return 0
    fi

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        echo ""
        return 1
    fi
    if ! declare -f _binance_fapi_signed_get >/dev/null 2>&1; then
        echo ""
        return 1
    fi

    resp=$(_binance_fapi_signed_get "/fapi/v1/leverageBracket" "symbol=${symbol}")
    max_lev=$(echo "$resp" | jq -r --arg s "$symbol" '
        if type == "array" then
            [.[] | select(.symbol == $s) | .brackets[]? | .initialLeverage? | tonumber?]
            | max
        else
            empty
        end' 2>/dev/null)

    if [ -z "$max_lev" ] || [ "$max_lev" = "null" ]; then
        echo ""
        return 1
    fi

    _bwl_set MAX_LEV "$symbol" "$max_lev"
    echo "$max_lev"
}

# Resolve leverage to apply: max for symbol or fixed LEVERAGE
resolve_leverage_for_symbol() {
    local symbol="$1"
    local max_lev

    if _leverage_mode_is_max; then
        max_lev=$(futures_get_symbol_max_leverage "$symbol")
        if [ -n "$max_lev" ] && awk -v v="$max_lev" 'BEGIN { exit (v + 0 > 0) ? 0 : 1 }' 2>/dev/null; then
            echo "$max_lev"
            return 0
        fi
    fi
    echo "${LEVERAGE:-5}"
}

# POST /fapi/v1/leverage — echoes applied leverage or empty on failure
futures_set_symbol_leverage() {
    local symbol="$1"
    local lev="${2:-}"
    local log_fn="${3:-}"
    local query_string signature response applied err

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    [ -z "$lev" ] && lev=$(resolve_leverage_for_symbol "$symbol")
    if [ -z "$lev" ] || ! awk -v v="$lev" 'BEGIN { exit (v + 0 > 0) ? 0 : 1 }' 2>/dev/null; then
        return 1
    fi

    if ! declare -f binance_timestamp_ms >/dev/null 2>&1; then
        return 1
    fi

    local timestamp
    timestamp=$(binance_timestamp_ms)
    query_string="symbol=${symbol}&leverage=${lev}&timestamp=${timestamp}&recvWindow=5000"
    signature=$(echo -n "$query_string" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | awk '{print $2}')

    response=$(curl -s -X POST "https://fapi.binance.com/fapi/v1/leverage" \
        -H "X-MBX-APIKEY: $BINANCE_API_KEY" \
        -d "${query_string}&signature=${signature}" 2>/dev/null)

    applied=$(echo "$response" | jq -r '.leverage // empty' 2>/dev/null)
    err=$(echo "$response" | jq -r '.msg // empty' 2>/dev/null)

    if [ -n "$applied" ] && [ "$applied" != "null" ]; then
        _bwl_set APPLIED_LEV "$symbol" "$applied"
        [ -n "$log_fn" ] && $log_fn "⚙️ $symbol: leverage set to ${applied}x"
        echo "$applied"
        return 0
    fi

    [ -n "$log_fn" ] && $log_fn "⚠️ $symbol: leverage ${lev}x failed: ${err:-$response}"
    return 1
}

# Notional USDT for next order (wallet % or fixed POSITION_SIZE_USDT)
calculate_position_notional_usdt() {
    local wallet pct notional

    if _position_size_uses_wallet_pct; then
        pct="${POSITION_WALLET_PCT:-10}"
        wallet=$(futures_get_wallet_balance_usdt)
        if [ -n "$wallet" ] && awk -v w="$wallet" -v p="$pct" 'BEGIN { exit (w + 0 > 0 && p + 0 > 0) ? 0 : 1 }' 2>/dev/null; then
            notional=$(echo "scale=8; $wallet * $pct / 100" | bc -l 2>/dev/null)
            if [ -n "$notional" ] && awk -v n="$notional" 'BEGIN { exit (n + 0 > 0) ? 0 : 1 }' 2>/dev/null; then
                echo "$notional"
                return 0
            fi
        fi
    fi

    echo "${POSITION_SIZE_USDT:-50}"
}
