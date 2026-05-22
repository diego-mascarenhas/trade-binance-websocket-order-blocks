#!/bin/bash
# Move SL toward LOCK_PROFIT_SL_AT_PCT of entry→TP when progress reaches LOCK_PROFIT_BE_PCT (TP unchanged)

# Progress from entry toward TP (0–100). Echoes 0 if invalid.
_lock_profit_progress_pct() {
    local direction="$1" entry="$2" tp="$3" price="$4"
    local total traveled pct

    if [ -z "$entry" ] || [ -z "$tp" ] || [ -z "$price" ]; then
        echo "0"
        return 0
    fi
    if ! _bn_is_positive "$entry" || ! _bn_is_positive "$price"; then
        echo "0"
        return 0
    fi

    case "$(echo "$direction" | tr '[:upper:]' '[:lower:]')" in
        long)
            total=$(echo "$tp - $entry" | bc -l 2>/dev/null)
            traveled=$(echo "$price - $entry" | bc -l 2>/dev/null)
            ;;
        short)
            total=$(echo "$entry - $tp" | bc -l 2>/dev/null)
            traveled=$(echo "$entry - $price" | bc -l 2>/dev/null)
            ;;
        *)
            echo "0"
            return 0
            ;;
    esac

    if [ -z "$total" ] || ! (( $(echo "$total > 0" | bc -l 2>/dev/null) )); then
        echo "0"
        return 0
    fi
    if [ -z "$traveled" ] || (( $(echo "$traveled <= 0" | bc -l 2>/dev/null) )); then
        echo "0"
        return 0
    fi

    pct=$(echo "scale=2; ($traveled / $total) * 100" | bc -l 2>/dev/null)
    echo "${pct:-0}"
}

# Cancel open STOP algo orders only (leave TAKE_PROFIT_* intact)
futures_cancel_sl_algo_orders() {
    local symbol="$1"
    local log_fn="${2:-}"
    local resp cancelled=0 dry_run algo_id del_resp

    dry_run="${DRY_RUN:-false}"
    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi

    resp=$(_binance_fapi_signed_get "/fapi/v1/openAlgoOrders" "symbol=${symbol}")
    [ -z "$resp" ] && return 1
    echo "$resp" | jq -e '.total // .orders // .[0]' >/dev/null 2>&1 || return 1

    while IFS= read -r algo_id; do
        [ -z "$algo_id" ] || [ "$algo_id" = "null" ] && continue
        if [ "$dry_run" = true ]; then
            cancelled=$((cancelled + 1))
            continue
        fi
        del_resp=$(_binance_fapi_signed_delete "/fapi/v1/algoOrder" "symbol=${symbol}&algoId=${algo_id}")
        if echo "$del_resp" | jq -e '.algoId' >/dev/null 2>&1; then
            cancelled=$((cancelled + 1))
        elif [ -n "$log_fn" ]; then
            $log_fn "⚠️ Cancel SL algo $symbol algoId=$algo_id: $del_resp"
        fi
    done < <(echo "$resp" | jq -r '
        (if .orders then .orders else . end) | .[]?
        | select(.orderType == "STOP_MARKET" or .orderType == "STOP" or .type == "STOP_MARKET")
        | select(
            (.algoStatus // .status // "NEW") == "NEW"
            or (.algoStatus // .status) == "ACTIVE"
          )
        | .algoId' 2>/dev/null)

    echo "$cancelled"
}

# Replace SL with a tighter stop; does not touch TP algos. Return 0 on success.
futures_move_sl_algo() {
    local symbol="$1" direction="$2" new_sl="$3" qty="$4" log_fn="${5:-}"

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    if [ -z "$new_sl" ] || ! _bn_is_positive "$new_sl" \
        || [ -z "$qty" ] || ! _bn_is_positive "$qty"; then
        return 1
    fi

    local cancelled
    cancelled=$(futures_cancel_sl_algo_orders "$symbol" "$log_fn")
    if [ "${cancelled:-0}" -gt 0 ] && [ "${DRY_RUN:-false}" != true ]; then
        sleep 0.25
    fi

    if _futures_place_reduce_conditional "$symbol" "$direction" "STOP_MARKET" "$new_sl" "$qty" "$log_fn"; then
        if declare -f ob_set >/dev/null 2>&1; then
            ob_set LAST_SL "$symbol" "$new_sl"
        fi
        return 0
    fi
    return 1
}

# Break-even / lock-profit: tighten SL when price has traveled LOCK_PROFIT_BE_PCT% toward TP
futures_try_lock_profit() {
    local symbol="$1"
    local current_price="$2"
    local log_fn="${3:-}"

    local enabled="${LOCK_PROFIT_ENABLED:-true}"
    case "$(echo "$enabled" | tr '[:upper:]' '[:lower:]')" in
        false|0|no|off) return 1 ;;
    esac

    if [ "${ORDER_EXECUTION_MODE:-rest}" != "rest" ]; then
        return 1
    fi

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    if [ -z "$current_price" ] || ! _bn_is_positive "$current_price"; then
        return 1
    fi
    if ! declare -f futures_get_position >/dev/null 2>&1 \
        || ! declare -f ob_get >/dev/null 2>&1; then
        return 1
    fi

    local pos_info direction entry tp last_sl stage qty
    if declare -f sync_symbol_position_flags >/dev/null 2>&1; then
        sync_symbol_position_flags "$symbol"
    fi

    pos_info=$(futures_get_position "$symbol")
    if [ "$pos_info" = "none" ]; then
        return 1
    fi

    direction=$(echo "$pos_info" | cut -d'|' -f1)
    qty=$(echo "$pos_info" | cut -d'|' -f2)
    if ! futures_position_is_significant "$symbol" "$qty"; then
        return 1
    fi

    entry=$(ob_get LAST_ENTRY "$symbol")
    tp=$(ob_get LAST_TP "$symbol")
    if [ -z "$entry" ] || [ "$entry" = "0" ]; then
        if declare -f futures_get_position_entry_price >/dev/null 2>&1; then
            entry=$(futures_get_position_entry_price "$symbol" "$direction" 2>/dev/null)
            if [ -n "$entry" ] && _bn_is_positive "$entry"; then
                ob_set LAST_ENTRY "$symbol" "$entry"
            fi
        fi
    fi
    if [ -z "$tp" ] || [ "$tp" = "0" ]; then
        if declare -f futures_get_open_sl_tp >/dev/null 2>&1; then
            local sl_tp_h
            sl_tp_h=$(futures_get_open_sl_tp "$symbol" "$direction" 2>/dev/null || echo "|")
            tp=$(echo "$sl_tp_h" | cut -d'|' -f2)
            if [ -n "$tp" ] && [ "$tp" != "null" ] && _bn_is_positive "$tp"; then
                ob_set LAST_TP "$symbol" "$tp"
            fi
        fi
    fi
    last_sl=$(ob_get LAST_SL "$symbol")
    stage=$(ob_get LOCK_PROFIT_STAGE "$symbol")
    [ "$stage" = "0" ] && stage=""

    if [ -z "$entry" ] || [ "$entry" = "0" ] || [ -z "$tp" ] || [ "$tp" = "0" ]; then
        return 1
    fi

    local progress be_pct stage2_pct buffer_pct lock_ratio sl_at_pct new_sl
    progress=$(_lock_profit_progress_pct "$direction" "$entry" "$tp" "$current_price")
    be_pct="${LOCK_PROFIT_BE_PCT:-50}"
    sl_at_pct="${LOCK_PROFIT_SL_AT_PCT:-20}"
    stage2_pct="${LOCK_PROFIT_STAGE2_PCT:-0}"
    buffer_pct="${LOCK_PROFIT_BUFFER_PCT:-0.05}"
    lock_ratio="${LOCK_PROFIT_LOCK_RATIO:-0.5}"

    # Stage 2: lock part of open profit (optional; LOCK_PROFIT_STAGE2_PCT=0 disables)
    if [ -n "$stage2_pct" ] && [ "$stage2_pct" != "0" ] \
        && (( $(echo "$progress >= $stage2_pct" | bc -l 2>/dev/null) )) \
        && [ "$stage" != "lock" ]; then

        case "$(echo "$direction" | tr '[:upper:]' '[:lower:]')" in
            long)
                new_sl=$(echo "$entry + ($current_price - $entry) * $lock_ratio" | bc -l 2>/dev/null)
                if [ -n "$last_sl" ] && [ "$last_sl" != "0" ] \
                    && _bn_price_gt "$last_sl" "$new_sl"; then
                    return 1
                fi
                if _bn_price_gt "$new_sl" "$current_price"; then
                    return 1
                fi
                ;;
            short)
                new_sl=$(echo "$entry - ($entry - $current_price) * $lock_ratio" | bc -l 2>/dev/null)
                if [ -n "$last_sl" ] && [ "$last_sl" != "0" ] \
                    && _bn_price_lt "$last_sl" "$new_sl"; then
                    return 1
                fi
                if _bn_price_lt "$new_sl" "$current_price"; then
                    return 1
                fi
                ;;
            *)
                return 1
                ;;
        esac

        if declare -f round_price_for_symbol >/dev/null 2>&1; then
            new_sl=$(round_price_for_symbol "$symbol" "$new_sl")
        fi

        if futures_move_sl_algo "$symbol" "$direction" "$new_sl" "$qty" "$log_fn"; then
            ob_set LOCK_PROFIT_STAGE "$symbol" "lock"
            [ -n "$log_fn" ] && $log_fn "🔐 $symbol: SL locked ${lock_ratio}× profit @ $new_sl (${progress}% toward TP)"
            if declare -f log_trade >/dev/null 2>&1; then
                log_trade "LOCK_PROFIT $symbol $direction stage=lock sl=$new_sl progress=${progress}% entry=$entry tp=$tp"
            fi
            return 0
        fi
        return 1
    fi

    # Stage 1: move SL to LOCK_PROFIT_SL_AT_PCT% of entry→TP when progress >= LOCK_PROFIT_BE_PCT
    if [ "$stage" = "breakeven" ] || [ "$stage" = "lock_sl" ] || [ "$stage" = "lock" ]; then
        return 1
    fi

    if ! (( $(echo "$progress >= $be_pct" | bc -l 2>/dev/null) )); then
        return 1
    fi

    case "$(echo "$direction" | tr '[:upper:]' '[:lower:]')" in
        long)
            if [ -n "$sl_at_pct" ] && [ "$sl_at_pct" != "0" ] \
                && (( $(echo "$sl_at_pct > 0" | bc -l 2>/dev/null) )); then
                new_sl=$(echo "$entry + ($tp - $entry) * $sl_at_pct / 100" | bc -l 2>/dev/null)
            else
                new_sl=$(echo "$entry * (1 + $buffer_pct / 100)" | bc -l 2>/dev/null)
            fi
            if [ -n "$last_sl" ] && [ "$last_sl" != "0" ] \
                && _bn_price_gt "$last_sl" "$new_sl"; then
                return 1
            fi
            if _bn_price_gt "$new_sl" "$current_price"; then
                return 1
            fi
            ;;
        short)
            if [ -n "$sl_at_pct" ] && [ "$sl_at_pct" != "0" ] \
                && (( $(echo "$sl_at_pct > 0" | bc -l 2>/dev/null) )); then
                new_sl=$(echo "$entry - ($entry - $tp) * $sl_at_pct / 100" | bc -l 2>/dev/null)
            else
                new_sl=$(echo "$entry * (1 - $buffer_pct / 100)" | bc -l 2>/dev/null)
            fi
            if [ -n "$last_sl" ] && [ "$last_sl" != "0" ] \
                && _bn_price_lt "$last_sl" "$new_sl"; then
                return 1
            fi
            if _bn_price_lt "$new_sl" "$current_price"; then
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac

    if declare -f round_price_for_symbol >/dev/null 2>&1; then
        new_sl=$(round_price_for_symbol "$symbol" "$new_sl")
    fi

    if futures_move_sl_algo "$symbol" "$direction" "$new_sl" "$qty" "$log_fn"; then
        ob_set LOCK_PROFIT_STAGE "$symbol" "lock_sl"
        [ -n "$log_fn" ] && $log_fn "🛡️ $symbol: SL → ${sl_at_pct}% entry→TP @ $new_sl (trigger ${progress}%≥${be_pct}% toward TP)"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "LOCK_PROFIT $symbol $direction stage=lock_sl sl=$new_sl sl_at=${sl_at_pct}% trigger=${be_pct}% progress=${progress}% entry=$entry tp=$tp"
        fi
        if declare -f send_telegram_bot >/dev/null 2>&1; then
            send_telegram_bot "$symbol futures
SL moved to ${sl_at_pct}% entry→TP @ $new_sl (trigger ${be_pct}% toward TP)"
        fi
        return 0
    fi

    return 1
}
