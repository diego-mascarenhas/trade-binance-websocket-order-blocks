#!/bin/bash
# Binance Futures: duplicate order guard + close on opposite OB touch

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f ob_zone_touch_signal >/dev/null 2>&1; then
    # shellcheck source=lib/ob_zone_signal.sh
    source "$_LIB_DIR/ob_zone_signal.sh"
fi
if ! declare -f _bn_is_positive >/dev/null 2>&1; then
    if [ -f "$_LIB_DIR/binance_precision.sh" ]; then
        # shellcheck source=lib/binance_precision.sh
        source "$_LIB_DIR/binance_precision.sh"
    else
        _bn_is_positive() {
            awk -v v="$1" 'BEGIN { exit (v + 0 > 0) ? 0 : 1 }'
        }
    fi
fi

_binance_fapi_signed_get() {
    local path="$1"
    local extra_qs="${2:-}"

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    if ! declare -f binance_timestamp_ms >/dev/null 2>&1; then
        return 1
    fi

    local timestamp qs sig url
    timestamp=$(binance_timestamp_ms)
    qs="timestamp=${timestamp}&recvWindow=5000"
    if [ -n "$extra_qs" ]; then
        qs="${extra_qs}&${qs}"
    fi
    sig=$(echo -n "$qs" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | awk '{print $2}')
    url="https://fapi.binance.com${path}?${qs}&signature=${sig}"
    curl -s -X GET "$url" -H "X-MBX-APIKEY: $BINANCE_API_KEY" 2>/dev/null
}

_binance_fapi_signed_post() {
    local path="$1"
    local body_qs="$2"

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    if ! declare -f binance_timestamp_ms >/dev/null 2>&1; then
        return 1
    fi

    local timestamp qs sig url response
    timestamp=$(binance_timestamp_ms)
    qs="${body_qs}&timestamp=${timestamp}&recvWindow=5000"
    sig=$(echo -n "$qs" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | awk '{print $2}')
    url="https://fapi.binance.com${path}"
    response=$(curl -s -X POST "$url" \
        -H "X-MBX-APIKEY: $BINANCE_API_KEY" \
        -d "${qs}&signature=${sig}" 2>/dev/null)
    echo "$response"
}

# Ignore dust / rounding leftovers (default 1 USDT notional)
BINANCE_MIN_POSITION_USDT="${BINANCE_MIN_POSITION_USDT:-1.0}"

_futures_position_notional_usd() {
    local symbol="$1"
    local qty="$2"
    local mark notional
    if ! declare -f get_futures_mark_price >/dev/null 2>&1; then
        echo "0"
        return 0
    fi
    mark=$(get_futures_mark_price "$symbol")
    if [ -z "$mark" ] || ! _bn_is_positive "$mark"; then
        echo "0"
        return 0
    fi
    notional=$(echo "scale=8; $qty * $mark" | bc -l 2>/dev/null)
    echo "${notional:-0}"
}

# return 0 if position size is worth tracking (not dust)
futures_position_is_significant() {
    local symbol="$1"
    local qty="$2"
    local min_usd notional
    min_usd="${BINANCE_MIN_POSITION_USDT:-1.0}"
    if [ -z "$qty" ] || ! _bn_is_positive "$qty"; then
        return 1
    fi
    notional=$(_futures_position_notional_usd "$symbol" "$qty")
    if [ -z "$notional" ]; then
        return 1
    fi
    awk -v n="$notional" -v m="$min_usd" 'BEGIN { exit (n + 0 >= m + 0) ? 0 : 1 }'
}

# Notify Telegram when position actually closed (SL/TP fill), using realized PnL from userTrades.
futures_notify_position_exit() {
    local symbol="$1"

    if ! declare -f ob_get >/dev/null 2>&1; then
        return 0
    fi
    if [ "$(ob_get_default EXIT_NOTIFIED "$symbol" "")" = "1" ]; then
        return 0
    fi

    local direction sl tp last_price last_qty realized pnl_msg
    direction=$(ob_get POS_DIR "$symbol")
    sl=$(ob_get LAST_SL "$symbol")
    tp=$(ob_get LAST_TP "$symbol")
    [ "$direction" = "0" ] && direction=""
    [ -z "$direction" ] && return 0

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 0
    fi

    local resp
    resp=$(_binance_fapi_signed_get "/fapi/v1/userTrades" "symbol=${symbol}&limit=30")
    if ! echo "$resp" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
        return 1
    fi

    last_price=$(echo "$resp" | jq -r '
        [.[] | select((.realizedPnl | tonumber? // 0) != 0)] | last | .price // empty' 2>/dev/null)
    last_qty=$(echo "$resp" | jq -r '
        [.[] | select((.realizedPnl | tonumber? // 0) != 0)] | last | .qty // empty' 2>/dev/null)
    realized=$(echo "$resp" | jq -r '
        [.[] | select((.realizedPnl | tonumber? // 0) != 0)] | last | .realizedPnl // empty' 2>/dev/null)

    if [ -z "$last_price" ] || [ "$last_price" = "null" ]; then
        return 1
    fi

    ob_set EXIT_NOTIFIED "$symbol" "1"

    if declare -f log_trade >/dev/null 2>&1; then
        log_trade "CLOSE $symbol $direction exit_price=$last_price qty=${last_qty:-?} realizedPnl=$realized"
    fi

    if awk -v p="$realized" 'BEGIN { exit (p + 0 > 0) ? 0 : 1 }' 2>/dev/null; then
        pnl_msg="TAKE_PROFIT #TP @ $last_price (qty ${last_qty:-?})"
        if [ -n "$tp" ] && [ "$tp" != "0" ]; then
            pnl_msg="TAKE_PROFIT #TP @ $last_price (target $tp, qty ${last_qty:-?})"
        fi
        if declare -f send_telegram_tp >/dev/null 2>&1; then
            send_telegram_tp "$symbol futures
$pnl_msg"
        fi
        return 0
    fi

    if awk -v p="$realized" 'BEGIN { exit (p + 0 < 0) ? 0 : 1 }' 2>/dev/null; then
        pnl_msg="STOP_MARKET #SL @ $last_price (qty ${last_qty:-?})"
        if [ -n "$sl" ] && [ "$sl" != "0" ]; then
            pnl_msg="STOP_MARKET #SL @ $last_price (stop $sl, qty ${last_qty:-?})"
        fi
        if declare -f send_telegram_sl >/dev/null 2>&1; then
            send_telegram_sl "$symbol futures
$pnl_msg"
        fi
        return 0
    fi

    if declare -f send_telegram_bot >/dev/null 2>&1; then
        send_telegram_bot "$symbol futures
#CLOSED $direction @ $last_price (qty ${last_qty:-?}, PnL ~0)"
    fi
    return 0
}

# Echo entry price for a position leg (LONG|SHORT), or empty
futures_get_position_entry_price() {
    local symbol="$1"
    local leg="$2"
    local positions entry

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    leg=$(echo "$leg" | tr '[:lower:]' '[:upper:]')
    positions=$(_binance_fapi_signed_get "/fapi/v2/positionRisk" "symbol=${symbol}")
    entry=$(echo "$positions" | jq -r --arg sym "$symbol" --arg ps "$leg" '
        .[] | select(.symbol == $sym)
        | if ($ps == "LONG" or $ps == "SHORT") then
            select(.positionSide == $ps)
          else . end
        | select(.positionAmt != "0" and .positionAmt != "0.000" and .positionAmt != "0.0")
        | .entryPrice' 2>/dev/null | head -1)
    if [ -z "$entry" ] || [ "$entry" = "null" ]; then
        entry=$(echo "$positions" | jq -r --arg sym "$symbol" '
            .[] | select(.symbol == $sym)
            | select(.positionAmt != "0" and .positionAmt != "0.000" and .positionAmt != "0.0")
            | .entryPrice' 2>/dev/null | head -1)
    fi
    if declare -f _bn_sanitize_num >/dev/null 2>&1; then
        entry=$(_bn_sanitize_num "$entry")
    fi
    if [ -n "$entry" ] && _bn_is_positive "$entry" 2>/dev/null; then
        if declare -f round_price_for_symbol >/dev/null 2>&1; then
            entry=$(round_price_for_symbol "$symbol" "$entry")
        fi
        echo "$entry"
        return 0
    fi
    return 1
}

# Echo "sl|tp" from open algo orders for position direction (prices may be empty)
futures_get_open_sl_tp() {
    local symbol="$1"
    local direction="$2"
    local resp sl tp want_ps

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        echo "|"
        return 1
    fi
    direction=$(echo "$direction" | tr '[:lower:]' '[:upper:]')
    want_ps="$direction"
    resp=$(_binance_fapi_signed_get "/fapi/v1/openAlgoOrders" "symbol=${symbol}")
    [ -z "$resp" ] && echo "|" && return 1

    sl=$(echo "$resp" | jq -r --arg ps "$want_ps" '
        (if .orders then .orders else . end) | .[]?
        | select(.orderType == "STOP_MARKET" or .orderType == "STOP" or .type == "STOP_MARKET")
        | select(
            (.algoStatus // .status // "NEW") == "NEW"
            or (.algoStatus // .status) == "ACTIVE"
          )
        | select(
            ($ps == "") or (.positionSide // "") == $ps or (.positionSide // "") == ""
          )
        | (.triggerPrice // .stopPrice // .price) | tostring' 2>/dev/null | head -1)

    tp=$(echo "$resp" | jq -r --arg ps "$want_ps" '
        (if .orders then .orders else . end) | .[]?
        | select(.orderType == "TAKE_PROFIT_MARKET" or .orderType == "TAKE_PROFIT" or .type == "TAKE_PROFIT_MARKET")
        | select(
            (.algoStatus // .status // "NEW") == "NEW"
            or (.algoStatus // .status) == "ACTIVE"
          )
        | select(
            ($ps == "") or (.positionSide // "") == $ps or (.positionSide // "") == ""
          )
        | (.triggerPrice // .stopPrice // .price) | tostring' 2>/dev/null | head -1)

    if declare -f round_price_for_symbol >/dev/null 2>&1; then
        [ -n "$sl" ] && [ "$sl" != "null" ] && sl=$(round_price_for_symbol "$symbol" "$sl")
        [ -n "$tp" ] && [ "$tp" != "null" ] && tp=$(round_price_for_symbol "$symbol" "$tp")
    fi
    echo "${sl:-}|${tp:-}"
}

# Set local ACTIVE / POS_DIR / LAST_* from an open leg on the exchange
_futures_hydrate_open_leg() {
    local symbol="$1"
    local direction="$2"
    local sl_tp entry sl tp

    ob_set ACTIVE "$symbol" "true"
    ob_set POS_DIR "$symbol" "$direction"
    ob_set EXIT_NOTIFIED "$symbol" ""

    if entry=$(futures_get_position_entry_price "$symbol" "$direction" 2>/dev/null); then
        ob_set LAST_ENTRY "$symbol" "$entry"
    fi

    sl_tp=$(futures_get_open_sl_tp "$symbol" "$direction" 2>/dev/null || echo "|")
    sl=$(echo "$sl_tp" | cut -d'|' -f1)
    tp=$(echo "$sl_tp" | cut -d'|' -f2)
    [ -n "$sl" ] && [ "$sl" != "null" ] && ob_set LAST_SL "$symbol" "$sl"
    [ -n "$tp" ] && [ "$tp" != "null" ] && ob_set LAST_TP "$symbol" "$tp"
}

# Mark symbol active from a pending entry LIMIT (no filled position yet)
_futures_hydrate_pending_entry() {
    local symbol="$1"
    local direction="$2"
    local limit_price="${3:-}"

    ob_set ACTIVE "$symbol" "true"
    ob_set POS_DIR "$symbol" "$direction"
    ob_set EXIT_NOTIFIED "$symbol" ""
    if [ -n "$limit_price" ] && [ "$limit_price" != "0" ]; then
        if declare -f round_price_for_symbol >/dev/null 2>&1; then
            limit_price=$(round_price_for_symbol "$symbol" "$limit_price")
        fi
        ob_set LAST_ENTRY "$symbol" "$limit_price"
    fi
}

# First pending entry LIMIT direction + price: LONG|price, SHORT|price, or empty
futures_get_pending_entry_limit() {
    local symbol="$1"
    local orders line oside pos_side direction price

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    orders=$(_binance_fapi_signed_get "/fapi/v1/openOrders" "symbol=${symbol}")
    [ -z "$orders" ] && return 1
    echo "$orders" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1

    for direction in LONG SHORT; do
        if futures_has_open_limit_same_side "$symbol" "$direction"; then
            line=$(echo "$orders" | jq -r --arg dir "$direction" '
                .[] | select(.type == "LIMIT" or .type == "LIMIT_MAKER")
                | . as $o
                | ($dir == "LONG") as $want_long
                | select(
                    if $want_long then .side == "BUY" else .side == "SELL" end
                  )
                | select(
                    ($dir == "LONG" and (($o.positionSide // "") == "LONG" or ($o.positionSide // "") == ""))
                    or ($dir == "SHORT" and (($o.positionSide // "") == "SHORT" or ($o.positionSide // "") == ""))
                  )
                | .price' 2>/dev/null | head -1)
            if [ -n "$line" ] && [ "$line" != "null" ]; then
                echo "${direction}|${line}"
                return 0
            fi
            echo "${direction}|"
            return 0
        fi
    done
    return 1
}

# On startup: sync all configured symbols and log open exposure (positions / pending limits)
sync_startup_configured_positions() {
    local log_fn="${1:-}"
    shift
    local symbols=("$@")
    local sym pos_info pending dual_warn=0 found=0
    local dir qty entry sl tp pending_line

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        [ -n "$log_fn" ] && $log_fn "⚠️ No API keys — skipping startup position sync"
        return 1
    fi
    if ! declare -f ob_set >/dev/null 2>&1; then
        return 1
    fi

    [ -n "$log_fn" ] && $log_fn "🔍 Syncing open positions for ${#symbols[@]} configured symbol(s)..."

    for sym in "${symbols[@]}"; do
        sync_symbol_position_flags "$sym"

        if declare -f futures_has_conflicting_entry_limits >/dev/null 2>&1 \
            && futures_has_conflicting_entry_limits "$sym"; then
            [ -n "$log_fn" ] && $log_fn "⚠️ $sym: LONG and SHORT entry limits on book — resolve manually"
            found=$((found + 1))
            continue
        fi

        if declare -f binance_is_hedge_mode >/dev/null 2>&1 && binance_is_hedge_mode; then
            local pos_long pos_short
            pos_long=$(futures_get_position "$sym" "LONG")
            pos_short=$(futures_get_position "$sym" "SHORT")
            if [ "$pos_long" != "none" ] && [ "$pos_short" != "none" ]; then
                dual_warn=$((dual_warn + 1))
                [ -n "$log_fn" ] && $log_fn "⚠️ $sym: dual hedge position (LONG + SHORT) — bot tracks primary leg only"
            fi
        fi

        if futures_has_open_position "$sym"; then
            pos_info=$(futures_get_position "$sym")
            dir=$(echo "$pos_info" | cut -d'|' -f1)
            qty=$(echo "$pos_info" | cut -d'|' -f2)
            entry=$(ob_get LAST_ENTRY "$sym")
            sl=$(ob_get LAST_SL "$sym")
            tp=$(ob_get LAST_TP "$sym")
            [ -n "$log_fn" ] && $log_fn "📍 $sym: open ${dir} position qty=${qty} entry=${entry:-?} sl=${sl:-?} tp=${tp:-?}"
            found=$((found + 1))
            continue
        fi

        if pending_line=$(futures_get_pending_entry_limit "$sym" 2>/dev/null); then
            dir=$(echo "$pending_line" | cut -d'|' -f1)
            entry=$(echo "$pending_line" | cut -d'|' -f2)
            [ -n "$log_fn" ] && $log_fn "📋 $sym: pending ${dir} entry limit @ ${entry:-?}"
            found=$((found + 1))
        fi
    done

    if [ "$found" -eq 0 ]; then
        [ -n "$log_fn" ] && $log_fn "✅ No open positions or entry limits on configured symbols"
    elif [ "$dual_warn" -gt 0 ]; then
        [ -n "$log_fn" ] && $log_fn "⚠️ ${dual_warn} symbol(s) with dual hedge exposure"
    fi
    return 0
}

# Sync local ACTIVE/DCA with exchange; hydrate entry/TP/SL when position or limit exists
sync_symbol_position_flags() {
    local symbol="$1"
    if ! declare -f ob_set >/dev/null 2>&1; then
        return 0
    fi
    local was_active=false skip_exit=0 suppress_ts pos_info pos_long pos_short
    local pending_line pending_dir pending_price

    if [ "$(ob_get ACTIVE "$symbol")" = "true" ]; then
        was_active=true
    fi

    if declare -f binance_is_hedge_mode >/dev/null 2>&1 && binance_is_hedge_mode; then
        pos_long=$(futures_get_position "$symbol" "LONG")
        pos_short=$(futures_get_position "$symbol" "SHORT")
        if [ "$pos_long" != "none" ] && [ "$pos_short" != "none" ]; then
            dual_open=true
            pos_info="$pos_long"
        elif [ "$pos_long" != "none" ]; then
            pos_info="$pos_long"
        elif [ "$pos_short" != "none" ]; then
            pos_info="$pos_short"
        else
            pos_info="none"
        fi
    else
        pos_info=$(futures_get_position "$symbol")
    fi

    if [ "$pos_info" != "none" ]; then
        local hydrate_dir
        hydrate_dir=$(echo "$pos_info" | cut -d'|' -f1)
        _futures_hydrate_open_leg "$symbol" "$hydrate_dir"
        return 0
    fi

    if pending_line=$(futures_get_pending_entry_limit "$symbol" 2>/dev/null); then
        pending_dir=$(echo "$pending_line" | cut -d'|' -f1)
        pending_price=$(echo "$pending_line" | cut -d'|' -f2)
        _futures_hydrate_pending_entry "$symbol" "$pending_dir" "$pending_price"
        return 0
    fi

    if [ "$was_active" = true ]; then
        suppress_ts=$(ob_get OB_CLOSE_SUPPRESS "$symbol")
        if [ -n "$suppress_ts" ] && [ "$suppress_ts" != "0" ]; then
            if [ $(($(date +%s) - suppress_ts)) -lt 120 ]; then
                skip_exit=1
            fi
        fi
        if [ "$skip_exit" -eq 0 ] && declare -f futures_notify_position_exit >/dev/null 2>&1; then
            futures_notify_position_exit "$symbol"
        fi
    fi

    ob_set ACTIVE "$symbol" "false"
    ob_set POS_DIR "$symbol" ""
    ob_set LAST_ENTRY "$symbol" ""
    ob_set LAST_TP "$symbol" ""
    ob_set LAST_SL "$symbol" ""
    ob_set LOCK_PROFIT_STAGE "$symbol" ""
    ob_set DCA_ACTIVE "$symbol" "false"
    ob_set DCA_DIR "$symbol" ""
    ob_set DCA_SL "$symbol" ""
    ob_set DCA_TP "$symbol" ""
    return 0
}

# Echo: none | LONG|<abs_qty> | SHORT|<abs_qty>
futures_get_position() {
    local symbol="$1"
    local prefer_side="${2:-}"
    local positions position_amt abs_amt direction

    if [ -z "$prefer_side" ] && declare -f ob_get >/dev/null 2>&1; then
        prefer_side=$(ob_get POS_DIR "$symbol")
        [ "$prefer_side" = "0" ] && prefer_side=""
    fi

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        echo "none"
        return 0
    fi

    positions=$(_binance_fapi_signed_get "/fapi/v2/positionRisk" "symbol=${symbol}")
    local row direction_hint
    if declare -f binance_is_hedge_mode >/dev/null 2>&1 && binance_is_hedge_mode; then
        if [ -n "$prefer_side" ]; then
            row=$(echo "$positions" | jq -r --arg sym "$symbol" --arg ps "$prefer_side" '
                .[] | select(.symbol == $sym and .positionSide == $ps)
                | select(.positionAmt != "0" and .positionAmt != "0.000" and .positionAmt != "0.0")
                | "\(.positionSide)|\(.positionAmt)"' 2>/dev/null | head -1)
        fi
        if [ -z "$row" ]; then
            row=$(echo "$positions" | jq -r ".[] | select(.symbol==\"$symbol\") | select(.positionAmt != \"0\" and .positionAmt != \"0.000\" and .positionAmt != \"0.0\") | \"\(.positionSide)|\(.positionAmt)\"" 2>/dev/null | head -1)
        fi
        direction_hint=$(echo "$row" | cut -d'|' -f1)
        position_amt=$(echo "$row" | cut -d'|' -f2)
    else
        position_amt=$(echo "$positions" | jq -r ".[] | select(.symbol==\"$symbol\") | .positionAmt" 2>/dev/null | head -1)
        direction_hint=""
    fi
    if declare -f _bn_sanitize_num >/dev/null 2>&1; then
        position_amt=$(_bn_sanitize_num "$position_amt")
    else
        position_amt=$(echo "$position_amt" | head -1 | tr -d '[:space:]')
    fi

    if [ -z "$position_amt" ] || [ "$position_amt" = "0" ] || [ "$position_amt" = "null" ]; then
        echo "none"
        return 0
    fi

    case "$(echo "$direction_hint" | tr '[:lower:]' '[:upper:]')" in
        LONG)
            direction="LONG"
            abs_amt=$(echo "$position_amt" | tr -d '-')
            ;;
        SHORT)
            direction="SHORT"
            abs_amt=$(echo "$position_amt" | tr -d '-')
            ;;
        *)
            if _bn_is_positive "$position_amt"; then
                direction="LONG"
                abs_amt="$position_amt"
            else
                direction="SHORT"
                abs_amt=$(echo "$position_amt" | tr -d '-')
            fi
            ;;
    esac

    if declare -f round_qty_for_symbol >/dev/null 2>&1; then
        abs_amt=$(round_qty_for_symbol "$symbol" "$abs_amt")
    fi

    if ! futures_position_is_significant "$symbol" "$abs_amt"; then
        echo "none"
        return 0
    fi

    echo "${direction}|${abs_amt}"
}

_binance_fapi_signed_delete() {
    local path="$1"
    local extra_qs="${2:-}"

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    if ! declare -f binance_timestamp_ms >/dev/null 2>&1; then
        return 1
    fi

    local timestamp qs sig url
    timestamp=$(binance_timestamp_ms)
    qs="timestamp=${timestamp}&recvWindow=5000"
    if [ -n "$extra_qs" ]; then
        qs="${extra_qs}&${qs}"
    fi
    sig=$(echo -n "$qs" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | awk '{print $2}')
    url="https://fapi.binance.com${path}?${qs}&signature=${sig}"
    curl -s -X DELETE "$url" -H "X-MBX-APIKEY: $BINANCE_API_KEY" 2>/dev/null
}

futures_cancel_open_orders() {
    local symbol="$1"
    _binance_fapi_signed_delete "/fapi/v1/allOpenOrders" "symbol=${symbol}" >/dev/null 2>&1
}

# Cancel open entry LIMIT orders (keeps STOP/TP/algo). direction: LONG|SHORT|empty=all entry limits.
# Echoes count cancelled; return 0 if any cancelled, 1 if none.
futures_cancel_open_entry_limits() {
    local symbol="$1"
    local direction="${2:-}"
    local log_fn="${3:-}"
    local dry_run cancelled=0 want_side want_pos_side

    dry_run="${DRY_RUN:-false}"
    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi

    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        LONG) want_side="BUY"; want_pos_side="LONG" ;;
        SHORT) want_side="SELL"; want_pos_side="SHORT" ;;
        *) want_side=""; want_pos_side="" ;;
    esac

    local orders
    orders=$(_binance_fapi_signed_get "/fapi/v1/openOrders" "symbol=${symbol}")
    [ -z "$orders" ] && return 1
    echo "$orders" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1

    while IFS= read -r oid oside opos; do
        [ -z "$oid" ] || [ "$oid" = "null" ] && continue
        if [ -n "$want_side" ] && [ "$oside" != "$want_side" ]; then
            continue
        fi
        if [ "${BINANCE_HEDGE_MODE:-false}" = true ] && [ -n "$want_pos_side" ] \
            && [ -n "$opos" ] && [ "$opos" != "$want_pos_side" ]; then
            continue
        fi

        if [ "$dry_run" = true ]; then
            cancelled=$((cancelled + 1))
            continue
        fi

        local resp
        resp=$(_binance_fapi_signed_delete "/fapi/v1/order" "symbol=${symbol}&orderId=${oid}")
        if echo "$resp" | jq -e '.orderId' >/dev/null 2>&1; then
            cancelled=$((cancelled + 1))
        elif [ -n "$log_fn" ]; then
            $log_fn "⚠️ Cancel limit $symbol orderId=$oid: $resp"
        fi
    done < <(echo "$orders" | jq -r '
        .[] | select(.type == "LIMIT" or .type == "LIMIT_MAKER")
        | select((.reduceOnly // false) == false)
        | "\(.orderId)|\(.side)|\(.positionSide // "")"' 2>/dev/null)

    if [ "$cancelled" -gt 0 ]; then
        [ -n "$log_fn" ] && $log_fn "🗑️ $symbol: cancelled $cancelled stale entry LIMIT order(s)"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "CANCEL_STALE_LIMITS $symbol count=$cancelled direction=${direction:-ALL}"
        fi
        if declare -f sync_symbol_position_flags >/dev/null 2>&1; then
            sync_symbol_position_flags "$symbol"
        elif declare -f ob_set >/dev/null 2>&1; then
            ob_set ACTIVE "$symbol" "false"
            ob_set POS_DIR "$symbol" ""
            ob_set LAST_ENTRY "$symbol" ""
            ob_set LAST_TP "$symbol" ""
            ob_set LAST_SL "$symbol" ""
            ob_set LOCK_PROFIT_STAGE "$symbol" ""
        fi
        echo "$cancelled"
        return 0
    fi
    return 1
}

# Close open LONG/SHORT with MARKET (hedge: positionSide + qty; one-way: reduceOnly + qty)
futures_close_position_market() {
    local symbol="$1"
    local position_direction="$2"
    local quantity="$3"
    local log_fn="${4:-}"
    local side close_dir query_string response dry_run pos_info

    dry_run="${DRY_RUN:-false}"

    # Always refresh size/side from exchange (avoids stale qty → -2022)
    if declare -f futures_get_position >/dev/null 2>&1; then
        pos_info=$(futures_get_position "$symbol" "$position_direction")
        if [ "$pos_info" != "none" ]; then
            close_dir=$(echo "$pos_info" | cut -d'|' -f1)
            quantity=$(echo "$pos_info" | cut -d'|' -f2)
        fi
    fi

    case "$(echo "${close_dir:-$position_direction}" | tr '[:lower:]' '[:upper:]')" in
        LONG) side="SELL"; close_dir="LONG" ;;
        SHORT) side="BUY"; close_dir="SHORT" ;;
        *)
            return 1
            ;;
    esac

    if [ -z "$quantity" ] || ! _bn_is_positive "$quantity"; then
        return 1
    fi

    if [ "$dry_run" = true ]; then
        [ -n "$log_fn" ] && $log_fn "🔍 DRY-RUN: Would CLOSE $close_dir $symbol qty=$quantity (opposite OB)"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "DRY-RUN CLOSE $symbol $close_dir qty=$quantity reason=opposite_ob mode=REST"
        fi
        return 0
    fi

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        [ -n "$log_fn" ] && $log_fn "❌ Cannot close $symbol: API keys missing"
        return 1
    fi

    futures_cancel_open_orders "$symbol"

    # Hedge: MARKET + quantity + positionSide (closePosition invalid on MARKET → -4136)
    query_string="symbol=${symbol}&side=${side}&type=MARKET&quantity=${quantity}"
    if declare -f binance_is_hedge_mode >/dev/null 2>&1 && binance_is_hedge_mode; then
        if declare -f append_position_side_param >/dev/null 2>&1; then
            query_string=$(append_position_side_param "$close_dir" "$query_string")
        fi
    elif declare -f append_reduce_only_param >/dev/null 2>&1; then
        query_string=$(append_reduce_only_param "$query_string")
    else
        query_string="${query_string}&reduceOnly=true"
    fi

    response=$(_binance_fapi_signed_post "/fapi/v1/order" "$query_string")

    if echo "$response" | jq -e '.orderId' >/dev/null 2>&1; then
        [ -n "$log_fn" ] && $log_fn "✅ Closed $close_dir position on $symbol (qty $quantity) — opposite OB touch"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "CLOSE $symbol $close_dir qty=$quantity reason=opposite_ob mode=REST status=ok"
        fi
        if declare -f ob_set >/dev/null 2>&1; then
            ob_set ACTIVE "$symbol" "false"
            ob_set POS_DIR "$symbol" ""
            ob_set LAST_ENTRY "$symbol" ""
            ob_set LAST_TP "$symbol" ""
            ob_set LAST_SL "$symbol" ""
            ob_set LOCK_PROFIT_STAGE "$symbol" ""
            ob_set DCA_ACTIVE "$symbol" "false"
            ob_set DCA_DIR "$symbol" ""
            ob_set DCA_SL "$symbol" ""
            ob_set DCA_TP "$symbol" ""
            ob_set OB_CLOSE_SUPPRESS "$symbol" ""
            ob_set EXIT_NOTIFIED "$symbol" "1"
        fi
        if declare -f send_telegram_position >/dev/null 2>&1; then
            send_telegram_position "$close_dir" "$symbol futures
#CLOSED $close_dir — opposite order book (qty $quantity)"
        fi
        return 0
    fi

    [ -n "$log_fn" ] && $log_fn "❌ Close failed $symbol: $response"
    if declare -f log_trade >/dev/null 2>&1; then
        log_trade "FAILED CLOSE $symbol $close_dir qty=$quantity reason=opposite_ob response=$(echo "$response" | tr -d '\n')"
    fi
    if declare -f log_error >/dev/null 2>&1; then
        log_error "Close failed $symbol: $response"
    fi
    # No position / dust / invalid close → stop retrying and clear local flags
    if echo "$response" | grep -qE '"code":-2022|"code":-4136|"code":-2019|ReduceOnly|closePosition'; then
        if declare -f ob_set >/dev/null 2>&1; then
            ob_set OB_CLOSE_SUPPRESS "$symbol" "$(date +%s)"
        fi
        if declare -f sync_symbol_position_flags >/dev/null 2>&1; then
            sync_symbol_position_flags "$symbol"
            [ -n "$log_fn" ] && $log_fn "ℹ️ $symbol: no position to close on exchange (-2022) — flags cleared, suppressing retries 5m"
        fi
    fi
    return 1
}

# Return 0 if close was triggered (or dry-run); 1 if nothing to do
try_close_on_opposite_ob() {
    local symbol="$1"
    local current_price="$2"
    local upper_pct="${3:-75}"
    local lower_pct="${4:-25}"
    local log_fn="${5:-}"

    local close_flag="${CLOSE_ON_OPPOSITE:-true}"
    case "$(echo "$close_flag" | tr '[:upper:]' '[:lower:]')" in
        false|0|no|off) return 1 ;;
    esac

    local pos_info pos_dir pos_qty ob_zone suppress_ts now elapsed

    if declare -f ob_get >/dev/null 2>&1; then
        suppress_ts=$(ob_get OB_CLOSE_SUPPRESS "$symbol")
        if [ -n "$suppress_ts" ] && [ "$suppress_ts" != "0" ]; then
            now=$(date +%s)
            elapsed=$((now - suppress_ts))
            if [ "$elapsed" -lt 300 ]; then
                return 1
            fi
        fi
    fi

    if declare -f sync_symbol_position_flags >/dev/null 2>&1; then
        sync_symbol_position_flags "$symbol"
    fi

    pos_info=$(futures_get_position "$symbol")
    if [ "$pos_info" = "none" ]; then
        return 1
    fi

    pos_dir=$(echo "$pos_info" | cut -d'|' -f1)
    pos_qty=$(echo "$pos_info" | cut -d'|' -f2)
    ob_zone=$(ob_zone_touch_signal "$symbol" "$current_price" "$upper_pct" "$lower_pct")

    if [ "$pos_dir" = "LONG" ] && [ "$ob_zone" = "SHORT" ]; then
        [ -n "$log_fn" ] && $log_fn "🔄 $symbol: LONG open + price at resistance OB — closing"
        futures_close_position_market "$symbol" "LONG" "$pos_qty" "$log_fn"
        return $?
    fi

    if [ "$pos_dir" = "SHORT" ] && [ "$ob_zone" = "LONG" ]; then
        [ -n "$log_fn" ] && $log_fn "🔄 $symbol: SHORT open + price at support OB — closing"
        futures_close_position_market "$symbol" "SHORT" "$pos_qty" "$log_fn"
        return $?
    fi

    return 1
}

# Returns 0 if any entry LIMIT exists on LONG or SHORT side (any price)
futures_has_open_entry_limit_any() {
    local symbol="$1"
    futures_has_open_limit_same_side "$symbol" "LONG" \
        || futures_has_open_limit_same_side "$symbol" "SHORT"
}

# Returns 0 if both LONG and SHORT entry limits are on the book (hedge trap)
futures_has_conflicting_entry_limits() {
    local symbol="$1"
    futures_has_open_limit_same_side "$symbol" "LONG" \
        && futures_has_open_limit_same_side "$symbol" "SHORT"
}

# Returns 0 if futures position size is significant (not dust) on any leg
futures_has_open_position() {
    local symbol="$1"
    local pos_info pos_long pos_short
    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    if declare -f binance_is_hedge_mode >/dev/null 2>&1 && binance_is_hedge_mode; then
        pos_long=$(futures_get_position "$symbol" "LONG")
        pos_short=$(futures_get_position "$symbol" "SHORT")
        [ "$pos_long" != "none" ] && return 0
        [ "$pos_short" != "none" ] && return 0
        return 1
    fi
    pos_info=$(futures_get_position "$symbol")
    [ "$pos_info" != "none" ]
}

# Returns 0 if any open LIMIT exists for this symbol + direction (any price)
futures_has_open_limit_same_side() {
    local symbol="$1"
    local direction="$2"
    local side want_pos_side pos_side oside

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi

    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        LONG) side="BUY"; want_pos_side="LONG" ;;
        SHORT) side="SELL"; want_pos_side="SHORT" ;;
        *) return 1 ;;
    esac

    local orders count
    orders=$(_binance_fapi_signed_get "/fapi/v1/openOrders" "symbol=${symbol}")
    [ -z "$orders" ] && return 1
    echo "$orders" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1

    count=$(echo "$orders" | jq -r --arg side "$side" --arg ps "$want_pos_side" '
        [.[] | select(.type == "LIMIT" or .type == "LIMIT_MAKER")
         | select(.side == $side)
         | select(
             ($ps == "LONG" or $ps == "SHORT") as $hedge |
             if $hedge then (.positionSide // "") == $ps or (.positionSide // "") == "" else true end
           )
        ] | length' 2>/dev/null)

    if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
        return 0
    fi
    return 1
}

# Returns 0 if an open LIMIT order exists at the same price and side
futures_has_limit_at_price() {
    local symbol="$1"
    local direction="$2"
    local entry="$3"
    local side pos_side want_pos_side oside oprice rounded

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    if ! declare -f round_price_for_symbol >/dev/null 2>&1; then
        return 1
    fi

    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        LONG) side="BUY"; want_pos_side="LONG" ;;
        SHORT) side="SELL"; want_pos_side="SHORT" ;;
        *) return 1 ;;
    esac

    entry=$(round_price_for_symbol "$symbol" "$entry")
    [ -z "$entry" ] || [ "$entry" = "0" ] && return 1

    local orders
    orders=$(_binance_fapi_signed_get "/fapi/v1/openOrders" "symbol=${symbol}")
    [ -z "$orders" ] && return 1
    echo "$orders" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        oside=$(echo "$line" | cut -d'|' -f1)
        oprice=$(echo "$line" | cut -d'|' -f2)
        pos_side=$(echo "$line" | cut -d'|' -f3)
        [ "$oside" != "$side" ] && continue
        if [ "${BINANCE_HEDGE_MODE:-false}" = true ] && [ -n "$pos_side" ] && [ "$pos_side" != "$want_pos_side" ]; then
            continue
        fi
        rounded=$(round_price_for_symbol "$symbol" "$oprice")
        if [ "$rounded" = "$entry" ]; then
            return 0
        fi
    done < <(echo "$orders" | jq -r '
        .[] | select(.type == "LIMIT" or .type == "LIMIT_MAKER")
        | "\(.side)|\(.price)|\(.positionSide // "")"' 2>/dev/null)

    return 1
}

# return 0 = allowed to place | return 1 = blocked (skip)
can_place_new_order() {
    local symbol="$1"
    local direction="$2"
    local entry="$3"
    local log_fn="${4:-}"

    # Local memory fallback (no API keys)
    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        if declare -f ob_get >/dev/null 2>&1 && [ "$(ob_get ACTIVE "$symbol")" = "true" ]; then
            [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: position flagged active locally — skipping order"
            return 1
        fi
        return 0
    fi

    if futures_has_open_position "$symbol"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: open position on Binance — skipping order"
        return 1
    fi

    if futures_has_conflicting_entry_limits "$symbol"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: LONG and SHORT entry limits on book — skipping order"
        return 1
    fi

    local opposite_dir
    opposite_dir=$([ "$(echo "$direction" | tr '[:upper:]' '[:lower:]')" = "long" ] && echo "SHORT" || echo "LONG")
    if futures_has_open_limit_same_side "$symbol" "$opposite_dir"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: pending $opposite_dir limit — cancel/replace before $direction"
        return 1
    fi

    if futures_has_open_limit_same_side "$symbol" "$direction"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: pending $direction limit already on book — skipping order"
        return 1
    fi

    if futures_has_limit_at_price "$symbol" "$direction" "$entry"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: limit order already exists at $entry ($direction) — skipping"
        return 1
    fi

    return 0
}

# --- REST: SL/TP after LIMIT fill (REST_PLACE_SL_TP=true in .env) ---

_bn_price_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 > b + 0) ? 0 : 1 }'
}

_bn_price_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 < b + 0) ? 0 : 1 }'
}

# Wait for entry LIMIT fill; echoes executed quantity on success
futures_wait_limit_fill() {
    local symbol="$1"
    local order_id="$2"
    local max_wait="${3:-90}"
    local poll="${REST_SL_TP_POLL_INTERVAL:-2}"
    local elapsed=0
    local resp status exec_qty

    if [ -z "$order_id" ] || [ -z "$BINANCE_API_KEY" ]; then
        return 1
    fi

    while [ "$elapsed" -lt "$max_wait" ]; do
        resp=$(_binance_fapi_signed_get "/fapi/v1/order" "symbol=${symbol}&orderId=${order_id}")
        status=$(echo "$resp" | jq -r '.status // empty' 2>/dev/null)
        case "$status" in
            FILLED)
                exec_qty=$(echo "$resp" | jq -r '.executedQty // .origQty // empty' 2>/dev/null)
                if declare -f round_qty_for_symbol >/dev/null 2>&1; then
                    exec_qty=$(round_qty_for_symbol "$symbol" "$exec_qty")
                fi
                if [ -n "$exec_qty" ] && _bn_is_positive "$exec_qty"; then
                    echo "$exec_qty"
                    return 0
                fi
                return 1
                ;;
            CANCELED|EXPIRED|REJECTED)
                return 1
                ;;
        esac
        sleep "$poll"
        elapsed=$((elapsed + poll))
    done

    local pos_info pos_qty
    pos_info=$(futures_get_position "$symbol")
    if [ "$pos_info" != "none" ]; then
        pos_qty=$(echo "$pos_info" | cut -d'|' -f2)
        if [ -n "$pos_qty" ] && _bn_is_positive "$pos_qty"; then
            echo "$pos_qty"
            return 0
        fi
    fi
    return 1
}

# Place STOP_MARKET / TAKE_PROFIT_MARKET via Algo Order API (required since -4120 on /fapi/v1/order)
_futures_place_reduce_conditional() {
    local symbol="$1"
    local position_dir="$2"
    local order_type="$3"
    local stop_price="$4"
    local quantity="$5"
    local log_fn="${6:-}"

    local side query_string response dry_run
    dry_run="${DRY_RUN:-false}"

    case "$(echo "$position_dir" | tr '[:lower:]' '[:upper:]')" in
        LONG) side="SELL" ;;
        SHORT) side="BUY" ;;
        *) return 1 ;;
    esac

    if declare -f round_price_for_symbol >/dev/null 2>&1; then
        stop_price=$(round_price_for_symbol "$symbol" "$stop_price")
        quantity=$(round_qty_for_symbol "$symbol" "$quantity")
    fi

    if [ -z "$stop_price" ] || ! _bn_is_positive "$stop_price" \
        || [ -z "$quantity" ] || ! _bn_is_positive "$quantity"; then
        return 1
    fi

    if [ "$dry_run" = true ]; then
        [ -n "$log_fn" ] && $log_fn "🔍 DRY-RUN: Would place algo $order_type $position_dir $symbol trigger=$stop_price qty=$quantity"
        return 0
    fi

    query_string="symbol=${symbol}&algoType=CONDITIONAL&side=${side}&type=${order_type}&triggerPrice=${stop_price}&quantity=${quantity}&workingType=CONTRACT_PRICE"
    if declare -f binance_is_hedge_mode >/dev/null 2>&1 && binance_is_hedge_mode; then
        if declare -f append_position_side_param >/dev/null 2>&1; then
            query_string=$(append_position_side_param "$position_dir" "$query_string")
        fi
    else
        query_string="${query_string}&reduceOnly=true"
    fi

    response=$(_binance_fapi_signed_post "/fapi/v1/algoOrder" "$query_string")
    if echo "$response" | jq -e '.algoId' >/dev/null 2>&1; then
        return 0
    fi

    [ -n "$log_fn" ] && $log_fn "❌ $order_type (algo) failed $symbol: $response"
    if declare -f log_error >/dev/null 2>&1; then
        log_error "$order_type (algo) failed $symbol: $response"
    fi
    if declare -f log_trade >/dev/null 2>&1; then
        log_trade "FAILED ${order_type} $symbol $position_dir trigger=$stop_price qty=$quantity response=$(echo "$response" | tr -d '\n')"
    fi
    return 1
}

futures_place_sl_tp_after_entry() {
    local symbol="$1"
    local direction="$2"
    local sl="$3"
    local tp="$4"
    local quantity="$5"
    local entry_order_id="$6"
    local log_fn="${7:-}"

    local enabled="${REST_PLACE_SL_TP:-true}"
    case "$(echo "$enabled" | tr '[:upper:]' '[:lower:]')" in
        false|0|no|off) return 0 ;;
    esac

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi

    local fill_wait="${REST_SL_TP_FILL_WAIT:-90}"
    local fill_qty="$quantity"
    local waited_qty

    if [ -n "$entry_order_id" ] && [ "$entry_order_id" != "0" ]; then
        waited_qty=$(futures_wait_limit_fill "$symbol" "$entry_order_id" "$fill_wait")
        if [ -n "$waited_qty" ] && _bn_is_positive "$waited_qty"; then
            fill_qty="$waited_qty"
        else
            [ -n "$log_fn" ] && $log_fn "⏳ $symbol: entry limit not filled in ${fill_wait}s — SL/TP not placed (order may still be open)"
            if declare -f log_trade >/dev/null 2>&1; then
                log_trade "SKIP SL/TP $symbol $direction reason=entry_not_filled orderId=$entry_order_id wait=${fill_wait}s"
            fi
            return 1
        fi
    else
        local pos_info
        pos_info=$(futures_get_position "$symbol")
        if [ "$pos_info" != "none" ]; then
            fill_qty=$(echo "$pos_info" | cut -d'|' -f2)
        fi
    fi

    if [ -z "$fill_qty" ] || ! _bn_is_positive "$fill_qty"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: no position qty for SL/TP"
        return 1
    fi

    if declare -f round_price_for_symbol >/dev/null 2>&1; then
        sl=$(round_price_for_symbol "$symbol" "$sl")
        tp=$(round_price_for_symbol "$symbol" "$tp")
    fi

    local sl_ok=1 tp_ok=1
    local entry_ref
    entry_ref=$(ob_get LAST_ENTRY "$symbol" 2>/dev/null)
    [ -z "$entry_ref" ] && entry_ref="0"

    if [ -n "$sl" ] && _bn_is_positive "$sl"; then
        local sl_valid=0
        case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
            LONG)
                if _bn_price_lt "$sl" "$entry_ref" || [ "$entry_ref" = "0" ]; then
                    sl_valid=1
                fi
                ;;
            SHORT)
                if _bn_price_gt "$sl" "$entry_ref" || [ "$entry_ref" = "0" ]; then
                    sl_valid=1
                fi
                ;;
        esac
        if [ "$sl_valid" -eq 1 ]; then
            if _futures_place_reduce_conditional "$symbol" "$direction" "STOP_MARKET" "$sl" "$fill_qty" "$log_fn"; then
                sl_ok=0
                [ -n "$log_fn" ] && $log_fn "🛡️ $symbol: STOP_MARKET SL @ $sl (qty $fill_qty)"
                if declare -f log_trade >/dev/null 2>&1; then
                    log_trade "SL_PLACED $symbol $direction stop=$sl qty=$fill_qty mode=ALGO"
                fi
            fi
        else
            [ -n "$log_fn" ] && $log_fn "⚠️ $symbol: invalid SL $sl for $direction (entry $entry_ref) — skipped"
        fi
    fi

    if [ -n "$tp" ] && _bn_is_positive "$tp"; then
        local tp_valid=0
        case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
            LONG)
                if _bn_price_gt "$tp" "$entry_ref" || [ "$entry_ref" = "0" ]; then
                    tp_valid=1
                fi
                ;;
            SHORT)
                if _bn_price_lt "$tp" "$entry_ref" || [ "$entry_ref" = "0" ]; then
                    tp_valid=1
                fi
                ;;
        esac
        if [ "$tp_valid" -eq 1 ]; then
            if _futures_place_reduce_conditional "$symbol" "$direction" "TAKE_PROFIT_MARKET" "$tp" "$fill_qty" "$log_fn"; then
                tp_ok=0
                [ -n "$log_fn" ] && $log_fn "🎯 $symbol: TAKE_PROFIT_MARKET TP @ $tp (qty $fill_qty)"
                if declare -f log_trade >/dev/null 2>&1; then
                    log_trade "TP_PLACED $symbol $direction stop=$tp qty=$fill_qty mode=ALGO"
                fi
            fi
        else
            [ -n "$log_fn" ] && $log_fn "⚠️ $symbol: invalid TP $tp for $direction (entry $entry_ref) — skipped"
        fi
    fi

    # SL/TP Telegram is sent only on actual fill (futures_notify_position_exit), not when orders are placed.
    if [ "$sl_ok" -eq 0 ] || [ "$tp_ok" -eq 0 ]; then
        return 0
    fi

    [ -n "$log_fn" ] && $log_fn "⚠️ $symbol: could not place SL/TP on Binance"
    if declare -f log_trade >/dev/null 2>&1; then
        log_trade "FAILED SL_TP $symbol $direction sl=$sl tp=$tp"
    fi
    return 1
}
