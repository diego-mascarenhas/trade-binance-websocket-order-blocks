#!/bin/bash
# Binance Futures: One-way vs Hedge (dual) position mode for REST orders

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f binance_timestamp_ms >/dev/null 2>&1; then
    # shellcheck source=lib/binance_timestamp.sh
    source "$_LIB_DIR/binance_timestamp.sh"
fi

BINANCE_HEDGE_MODE=false

# return 0 if account uses dual-side (hedge) position mode
binance_is_hedge_mode() {
    case "$(echo "${BINANCE_HEDGE_MODE}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) return 0 ;;
    esac
    return 1
}

_binance_fapi_signature() {
    echo -n "$1" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | awk '{print $2}'
}

# Detect via API or BINANCE_POSITION_MODE env (hedge|oneway)
detect_binance_position_mode() {
    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi

    if [ -n "${BINANCE_POSITION_MODE:-}" ]; then
        case "$(echo "$BINANCE_POSITION_MODE" | tr '[:upper:]' '[:lower:]')" in
            hedge|dual|hedged)
                BINANCE_HEDGE_MODE=true
                return 0
                ;;
            oneway|one-way|single)
                BINANCE_HEDGE_MODE=false
                return 0
                ;;
            *)
                echo "❌ Invalid BINANCE_POSITION_MODE: $BINANCE_POSITION_MODE (use hedge or oneway)"
                return 1
                ;;
        esac
    fi

    local timestamp
    timestamp=$(binance_timestamp_ms)
    local recv_window=5000
    local qs="timestamp=${timestamp}&recvWindow=${recv_window}"
    local sig
    sig=$(_binance_fapi_signature "$qs")
    local resp
    resp=$(curl -s "https://fapi.binance.com/fapi/v1/positionSide/dual?${qs}&signature=${sig}" \
        -H "X-MBX-APIKEY: $BINANCE_API_KEY" 2>/dev/null)
    local dual
    dual=$(echo "$resp" | jq -r '.dualSidePosition // empty' 2>/dev/null)

    if [ "$dual" = "true" ]; then
        BINANCE_HEDGE_MODE=true
    elif [ "$dual" = "false" ]; then
        BINANCE_HEDGE_MODE=false
    else
        echo "⚠️  Could not detect position mode: $resp"
        BINANCE_HEDGE_MODE=false
        return 1
    fi
    return 0
}

# Append positionSide to order query when account is in Hedge Mode
append_position_side_param() {
    local direction="$1"
    local query_string="$2"
    if ! binance_is_hedge_mode; then
        echo "$query_string"
        return 0
    fi
    local pos_side="LONG"
    if [ "$direction" = "SHORT" ]; then
        pos_side="SHORT"
    fi
    echo "${query_string}&positionSide=${pos_side}"
}

# Hedge mode: reduceOnly is not allowed when positionSide is set (-1106)
append_reduce_only_param() {
    local query_string="$1"
    if binance_is_hedge_mode; then
        echo "$query_string"
        return 0
    fi
    echo "${query_string}&reduceOnly=true"
}
