#!/bin/bash
# DCA: min adverse move (DCA_TRIGGER_PCT), then same LIMIT entry as a normal signal

_dca_enabled() {
    case "$(echo "${DCA_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# % price moved against position since reference price
_dca_adverse_move_pct() {
    local direction="$1" ref_price="$2" current_price="$3"
    local move

    if [ -z "$ref_price" ] || [ -z "$current_price" ]; then
        echo "0"
        return 0
    fi
    if ! declare -f _bn_is_positive >/dev/null 2>&1 || \
        ! _bn_is_positive "$ref_price" || ! _bn_is_positive "$current_price"; then
        echo "0"
        return 0
    fi

    case "$(echo "$direction" | tr '[:upper:]' '[:lower:]')" in
        long)
            if awk -v c="$current_price" -v r="$ref_price" 'BEGIN { exit (c + 0 < r + 0) ? 0 : 1 }'; then
                move=$(echo "scale=8; ($ref_price - $current_price) * 100 / $ref_price" | bc -l 2>/dev/null)
                echo "${move:-0}"
                return 0
            fi
            ;;
        short)
            if awk -v c="$current_price" -v r="$ref_price" 'BEGIN { exit (c + 0 > r + 0) ? 0 : 1 }'; then
                move=$(echo "scale=8; ($current_price - $ref_price) * 100 / $ref_price" | bc -l 2>/dev/null)
                echo "${move:-0}"
                return 0
            fi
            ;;
    esac
    echo "0"
}

# Notional for next DCA add: base × multiplier^(step+1)
_dca_next_notional_usdt() {
    local symbol="$1"
    local step="$2"
    local base mult exp notional next_step

    base=$(ob_get DCA_BASE_NOTIONAL "$symbol")
    if [ -z "$base" ] || [ "$base" = "0" ] || ! _bn_is_positive "$base" 2>/dev/null; then
        if declare -f calculate_position_notional_usdt >/dev/null 2>&1; then
            base=$(calculate_position_notional_usdt)
        else
            base="${POSITION_SIZE_USDT:-50}"
        fi
    fi

    mult="${DCA_MULTIPLIER:-1.0}"
    next_step=$((step + 1))
    [ "$next_step" -lt 1 ] && next_step=1
    exp=$(echo "scale=8; $mult ^ $next_step" | bc -l 2>/dev/null)
    notional=$(echo "scale=8; $base * $exp" | bc -l 2>/dev/null)
    echo "${notional:-$base}"
}

# Echo USDT notional for the pending DCA order (current step on book)
calculate_dca_notional_usdt() {
    local symbol="$1"
    local step
    step=$(ob_get DCA_STEP "$symbol")
    [ "$step" = "0" ] && step=0
    step=${step:-0}
    _dca_next_notional_usdt "$symbol" "$step"
}

calculate_dca_quantity() {
    local symbol="$1"
    local entry_price="$2"
    local step notional raw_quantity

    if [ -z "$entry_price" ] || ! (( $(echo "$entry_price > 0" | bc -l 2>/dev/null) )); then
        echo "0.001"
        return 0
    fi

    step=$(ob_get DCA_STEP "$symbol")
    [ "$step" = "0" ] && step=0
    step=${step:-0}
    notional=$(_dca_next_notional_usdt "$symbol" "$step")

    if declare -f bc_safe_div >/dev/null 2>&1; then
        raw_quantity=$(bc_safe_div "$notional" "$entry_price")
    else
        raw_quantity=$(echo "scale=8; $notional / $entry_price" | bc -l 2>/dev/null)
    fi
    if declare -f round_qty_for_symbol >/dev/null 2>&1; then
        round_qty_for_symbol "$symbol" "$raw_quantity"
    else
        echo "$raw_quantity"
    fi
}

futures_dca_init_symbol() {
    local symbol="$1" direction="$2" ref_price="$3" base_notional="${4:-}"

    if ! _dca_enabled || ! declare -f ob_set >/dev/null 2>&1; then
        return 0
    fi

    if [ -z "$base_notional" ] || ! _bn_is_positive "$base_notional" 2>/dev/null; then
        if declare -f calculate_position_notional_usdt >/dev/null 2>&1; then
            base_notional=$(calculate_position_notional_usdt)
        else
            base_notional="${POSITION_SIZE_USDT:-50}"
        fi
    fi

    ob_set DCA_ACTIVE "$symbol" "true"
    ob_set DCA_DIR "$symbol" "$direction"
    ob_set DCA_STEP "$symbol" "0"
    ob_set DCA_BASE_NOTIONAL "$symbol" "$base_notional"
    if [ -n "$ref_price" ]; then
        if declare -f round_price_for_symbol >/dev/null 2>&1; then
            ref_price=$(round_price_for_symbol "$symbol" "$ref_price")
        fi
        ob_set DCA_LAST_ADD_PRICE "$symbol" "$ref_price"
    fi
    ob_set DCA_LAST_ADD_TS "$symbol" "$(date +%s)"
}

futures_dca_mark_add_placed() {
    local symbol="$1" direction="$2" ref_price="$3"
    local step

    if ! declare -f ob_set >/dev/null 2>&1; then
        return 0
    fi

    step=$(ob_get DCA_STEP "$symbol")
    [ "$step" = "0" ] && step=0
    step=$((step + 1))
    ob_set DCA_STEP "$symbol" "$step"
    ob_set DCA_DIR "$symbol" "$direction"
    ob_set DCA_ACTIVE "$symbol" "true"
    if [ -n "$ref_price" ]; then
        if declare -f round_price_for_symbol >/dev/null 2>&1; then
            ref_price=$(round_price_for_symbol "$symbol" "$ref_price")
        fi
        ob_set DCA_LAST_ADD_PRICE "$symbol" "$ref_price"
    fi
    ob_set DCA_LAST_ADD_TS "$symbol" "$(date +%s)"
}

futures_dca_reset_symbol() {
    local symbol="$1"
    if ! declare -f ob_set >/dev/null 2>&1; then
        return 0
    fi
    ob_set DCA_ACTIVE "$symbol" "false"
    ob_set DCA_DIR "$symbol" ""
    ob_set DCA_STEP "$symbol" ""
    ob_set DCA_BASE_NOTIONAL "$symbol" ""
    ob_set DCA_LAST_ADD_PRICE "$symbol" ""
    ob_set DCA_LAST_ADD_TS "$symbol" ""
}

futures_try_dca_add() {
    local symbol="$1"
    local current_price="$2"
    local log_fn="${3:-}"

    local trigger_pct max_steps cooldown_sec step last_ts now elapsed
    local pos_dir last_price adverse change spread notional
    local signal_data signal confidence entry reasons sl tp tp_sl_data

    if ! _dca_enabled; then
        return 1
    fi
    if [ "${ORDER_EXECUTION_MODE:-rest}" != "rest" ]; then
        return 1
    fi
    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    if ! declare -f futures_has_filled_position >/dev/null 2>&1 \
        || ! futures_has_filled_position "$symbol"; then
        return 1
    fi
    if declare -f is_trading_time_allowed >/dev/null 2>&1 && ! is_trading_time_allowed; then
        return 1
    fi

    trigger_pct="${DCA_TRIGGER_PCT:-0.4}"
    max_steps="${DCA_MAX_STEPS:-3}"
    cooldown_sec="${DCA_COOLDOWN_SECONDS:-120}"

    step=$(ob_get DCA_STEP "$symbol")
    [ "$step" = "0" ] && step=0
    step=${step:-0}
    if [ "$step" -ge "$max_steps" ] 2>/dev/null; then
        return 1
    fi

    last_ts=$(ob_get DCA_LAST_ADD_TS "$symbol")
    [ "$last_ts" = "0" ] && last_ts=0
    now=$(date +%s)
    if [ -n "$last_ts" ] && [ "$last_ts" -gt 0 ]; then
        elapsed=$((now - last_ts))
        if [ "$elapsed" -lt "$cooldown_sec" ]; then
            return 1
        fi
    fi

    pos_dir=$(ob_get POS_DIR "$symbol")
    [ "$pos_dir" = "0" ] && pos_dir=""
    if [ -z "$pos_dir" ]; then
        local pos_info
        pos_info=$(futures_get_position "$symbol")
        [ "$pos_info" = "none" ] && return 1
        pos_dir=$(echo "$pos_info" | cut -d'|' -f1)
    fi

    last_price=$(ob_get DCA_LAST_ADD_PRICE "$symbol")
    if [ -z "$last_price" ] || [ "$last_price" = "0" ]; then
        if declare -f futures_get_position_entry_price >/dev/null 2>&1; then
            last_price=$(futures_get_position_entry_price "$symbol" "$pos_dir" 2>/dev/null)
        fi
        [ -z "$last_price" ] && last_price=$(ob_get LAST_ENTRY "$symbol")
    fi
    [ -z "$last_price" ] || [ "$last_price" = "0" ] && return 1

    adverse=$(_dca_adverse_move_pct "$pos_dir" "$last_price" "$current_price")
    if [ -z "$adverse" ] || ! (( $(echo "$adverse >= $trigger_pct" | bc -l 2>/dev/null) )); then
        return 1
    fi

    if ! declare -f determine_signal_ob_core >/dev/null 2>&1 \
        || ! declare -f send_order_dca >/dev/null 2>&1 \
        || ! declare -f calculate_tp_sl >/dev/null 2>&1; then
        return 1
    fi

    change=$(ob_get CHANGE24 "$symbol")
    signal_data=$(determine_signal_ob_core "$symbol" "$current_price" "$change")
    signal=$(echo "$signal_data" | cut -d'|' -f1)
    confidence=$(echo "$signal_data" | cut -d'|' -f2)
    entry=$(echo "$signal_data" | cut -d'|' -f3)
    reasons=$(echo "$signal_data" | cut -d'|' -f4)

    if [ "$signal" = "NEUTRAL" ] || [ "$signal" != "$pos_dir" ]; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: DCA skipped — signal $signal (position $pos_dir, adverse ${adverse}%)"
        return 1
    fi

    if [ -z "${MIN_CONFIDENCE:-50}" ] || [ "$confidence" -lt "${MIN_CONFIDENCE:-50}" ] 2>/dev/null; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: DCA skipped — conf ${confidence}% < ${MIN_CONFIDENCE}%"
        return 1
    fi

    spread=0
    local best_bid best_ask
    best_bid=$(ob_get BID "$symbol")
    best_ask=$(ob_get ASK "$symbol")
    if [ "$best_bid" != "0" ] && [ "$best_ask" != "0" ] \
        && [ "$best_bid" != "null" ] && [ "$best_ask" != "null" ]; then
        spread=$(echo "$best_ask - $best_bid" | bc -l 2>/dev/null)
    fi

    tp_sl_data=$(calculate_tp_sl "$entry" "$signal" "$change" "$spread" "$symbol")
    sl=$(echo "$tp_sl_data" | cut -d'|' -f1)
    tp=$(echo "$tp_sl_data" | cut -d'|' -f2)
    notional=$(_dca_next_notional_usdt "$symbol" "$step")

    if [ "$DRY_RUN" = true ]; then
        [ -n "$log_fn" ] && $log_fn "🔍 DRY-RUN: Would DCA #$((step + 1)) $symbol $signal @ $entry notional=${notional} (adverse ${adverse}% ≥ ${trigger_pct}%) | $reasons"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "DRY-RUN DCA $symbol $signal step=$((step + 1)) entry=$entry notional=$notional sl=$sl tp=$tp adverse=${adverse}%"
        fi
        return 0
    fi

    [ -n "$log_fn" ] && $log_fn "📈 $symbol: DCA #$((step + 1)) trigger (${adverse}% ≥ ${trigger_pct}%) — $signal @ $entry notional=${notional} | $reasons"
    if declare -f log_trade >/dev/null 2>&1; then
        log_trade "DCA_SIGNAL $symbol $signal conf=${confidence}% step=$((step + 1)) entry=$entry notional=$notional tp=$tp sl=$sl adverse=${adverse}% | $reasons"
    fi

    send_order_dca "$symbol" "$signal" "$entry" "$sl" "$tp"
    return 0
}
