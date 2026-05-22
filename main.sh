#!/usr/bin/env bash

# ============================================
# Order Blocks Bot v5.0 (main.sh) — multi-symbol order book, position guards
# - Prevents duplicate orders on the same symbol
# - Functional order book analysis
# - Direct Binance REST order execution
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BINANCE_PRECISION_LIB="$SCRIPT_DIR/lib/binance_precision.sh"
if [ ! -f "$BINANCE_PRECISION_LIB" ]; then
    BINANCE_PRECISION_LIB="$SCRIPT_DIR/binance_precision.sh"
fi
if [ ! -f "$BINANCE_PRECISION_LIB" ]; then
    echo "❌ Error: lib/binance_precision.sh not found"
    echo "   Expected: $SCRIPT_DIR/lib/binance_precision.sh"
    echo "   Deploy the lib/ folder next to this script."
    exit 1
fi
# shellcheck source=lib/binance_precision.sh
source "$BINANCE_PRECISION_LIB"
if [ ! -f "$SCRIPT_DIR/lib/terminal_display.sh" ]; then
    echo "❌ Error: lib/terminal_display.sh not found in $SCRIPT_DIR/lib/"
    exit 1
fi
# shellcheck source=lib/terminal_display.sh
source "$SCRIPT_DIR/lib/terminal_display.sh"
if [ ! -f "$SCRIPT_DIR/lib/ob_symbol_state.sh" ]; then
    echo "❌ Error: lib/ob_symbol_state.sh not found in $SCRIPT_DIR/lib/"
    exit 1
fi
# shellcheck source=lib/ob_symbol_state.sh
source "$SCRIPT_DIR/lib/ob_symbol_state.sh"
if [ -f "$SCRIPT_DIR/lib/ob_wall_history.sh" ]; then
    # shellcheck source=lib/ob_wall_history.sh
    source "$SCRIPT_DIR/lib/ob_wall_history.sh"
fi
if [ ! -f "$SCRIPT_DIR/lib/binance_timestamp.sh" ]; then
    echo "❌ Error: lib/binance_timestamp.sh not found in $SCRIPT_DIR/lib/"
    exit 1
fi
# shellcheck source=lib/binance_timestamp.sh
source "$SCRIPT_DIR/lib/binance_timestamp.sh"
if [ -f "$SCRIPT_DIR/lib/binance_position_mode.sh" ]; then
    # shellcheck source=lib/binance_position_mode.sh
    source "$SCRIPT_DIR/lib/binance_position_mode.sh"
fi
if [ -f "$SCRIPT_DIR/lib/binance_order_guard.sh" ]; then
    # shellcheck source=lib/binance_order_guard.sh
    source "$SCRIPT_DIR/lib/binance_order_guard.sh"
fi
if [ -f "$SCRIPT_DIR/lib/binance_lock_profit.sh" ]; then
    # shellcheck source=lib/binance_lock_profit.sh
    source "$SCRIPT_DIR/lib/binance_lock_profit.sh"
fi

if [ -f .env ]; then
    source .env
fi

DRY_RUN=false
SYMBOL_CLI=""
SINGLE_SYMBOL_MODE=false

# ============================================
# CONFIGURATION
# ============================================

SYMBOLS="${SYMBOLS:-BTCUSDT,ETHUSDT,SOLUSDT}"
DEPTH="${DEPTH:-10}"
SPEED="${WS_SPEED:-500ms}"
ORDER_EXECUTION_MODE="${ORDER_EXECUTION_MODE:-rest}"

# Trading parameters
TP_PERCENT="${TP_PERCENT:-0.5}"
SL_PERCENT="${SL_PERCENT:-0.4}"
# TP_SL_MODE: percent (default) | ob_grid — SHORT SL=R1 TP=S0, LONG SL=S1 TP=R0
TP_SL_MODE="${TP_SL_MODE:-percent}"
OB_WALL_SHIFT_PCT="${OB_WALL_SHIFT_PCT:-0.15}"
SL_OB_BUFFER_PCT="${SL_OB_BUFFER_PCT:-0.05}"
TP_OB_BUFFER_PCT="${TP_OB_BUFFER_PCT:-0.05}"
OB_GRID_MIN_SL_PCT="${OB_GRID_MIN_SL_PCT:-}"
OB_GRID_MIN_R0_R1_GAP_PCT="${OB_GRID_MIN_R0_R1_GAP_PCT:-0.2}"
OB_GRID_SL_RANGE_RATIO="${OB_GRID_SL_RANGE_RATIO:-0.382}"
MIN_CONFIDENCE="${MIN_CONFIDENCE:-50}"

# Volatile settings
VOLATILE_THRESHOLD="${VOLATILE_THRESHOLD:-15}"
SL_VOLATILE_MIN="${SL_VOLATILE_MIN:-0.8}"
TP_VOLATILE_MIN="${TP_VOLATILE_MIN:-1.0}"
MIN_SL_SPREAD_MULT="${MIN_SL_SPREAD_MULT:-3}"

# Position size
POSITION_SIZE_USDT="${POSITION_SIZE_USDT:-50}"
LEVERAGE="${LEVERAGE:-5}"

# Cooldown between orders for same symbol (seconds)
ORDER_COOLDOWN_SECONDS="${ORDER_COOLDOWN:-300}"

# Cancel unfilled entry LIMIT(s) when a new signal arrives (REST only)
REPLACE_STALE_LIMITS="${REPLACE_STALE_LIMITS:-true}"

# Place STOP/TP on Binance after entry LIMIT fills (REST mode)
REST_PLACE_SL_TP="${REST_PLACE_SL_TP:-true}"
REST_SL_TP_FILL_WAIT="${REST_SL_TP_FILL_WAIT:-90}"
REST_SL_TP_POLL_INTERVAL="${REST_SL_TP_POLL_INTERVAL:-2}"

# Close open position when price touches opposite OB wall
CLOSE_ON_OPPOSITE="${CLOSE_ON_OPPOSITE:-true}"
ZONE_UPPER_PCT="${ZONE_UPPER_PCT:-75}"
ZONE_LOWER_PCT="${ZONE_LOWER_PCT:-25}"

# Lock profit: move SL toward break-even as price advances toward TP (TP unchanged)
LOCK_PROFIT_ENABLED="${LOCK_PROFIT_ENABLED:-true}"
LOCK_PROFIT_BE_PCT="${LOCK_PROFIT_BE_PCT:-50}"
LOCK_PROFIT_SL_AT_PCT="${LOCK_PROFIT_SL_AT_PCT:-20}"
LOCK_PROFIT_BUFFER_PCT="${LOCK_PROFIT_BUFFER_PCT:-0.05}"
LOCK_PROFIT_STAGE2_PCT="${LOCK_PROFIT_STAGE2_PCT:-0}"
LOCK_PROFIT_LOCK_RATIO="${LOCK_PROFIT_LOCK_RATIO:-0.5}"

# Binance API
BINANCE_API_KEY="${BINANCE_API_KEY:-}"
BINANCE_SECRET_KEY="${BINANCE_SECRET_KEY:-}"

# Finandy (fallback)
FINANDY_SECRET="${FINANDY_SECRET:-d1a01uf5uoe}"
FINANDY_WEBHOOK="${FINANDY_WEBHOOK:-https://hook.finandy.com/LMEnRji-3GvFkm7wqFUK}"

# Telegram
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
BOT_LOG_BASE_DIR="$SCRIPT_DIR"
LOG_FILE="${LOG_FILE:-$LOG_DIR/bot.log}"
ERROR_LOG_FILE="${ERROR_LOG_FILE:-$LOG_DIR/errors.log}"
TRADES_LOG_FILE="${TRADES_LOG_FILE:-$LOG_DIR/trades.log}"
# Absolute paths so background jobs and tail -f always hit the same files
[[ "$LOG_FILE" != /* ]] && LOG_FILE="$SCRIPT_DIR/${LOG_FILE#./}"
[[ "$ERROR_LOG_FILE" != /* ]] && ERROR_LOG_FILE="$SCRIPT_DIR/${ERROR_LOG_FILE#./}"
[[ "$TRADES_LOG_FILE" != /* ]] && TRADES_LOG_FILE="$SCRIPT_DIR/${TRADES_LOG_FILE#./}"
TRADES_LOG_HEARTBEAT_SECONDS="${TRADES_LOG_HEARTBEAT_SECONDS:-300}"
LAST_TRADES_HEARTBEAT=0
if [ -f "$SCRIPT_DIR/lib/bot_trade_log.sh" ]; then
    # shellcheck source=lib/bot_trade_log.sh
    source "$SCRIPT_DIR/lib/bot_trade_log.sh"
else
    log_trade() { :; }
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================
# OPEN POSITION CONTROL
# ============================================

# Position flags use ob_set/ob_get (see lib/ob_symbol_state.sh)

# ============================================
# FUNCTIONS
# ============================================

# Ring buffer for dashboard footer (logs never print to stdout — avoids overlapping the table)
LAST_LOG_EVENT=""
declare -a _LOG_RING=()
_LOG_RING_MAX=2

_log_push_event() {
    local short="$1"
    LAST_LOG_EVENT="$short"
    _LOG_RING+=("$short")
    while [ "${#_LOG_RING[@]}" -gt "$_LOG_RING_MAX" ]; do
        _LOG_RING=("${_LOG_RING[@]:1}")
    done
}

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$line" >> "$LOG_FILE"
    _log_push_event "$1"
    # Optional: LOG_TO_STDERR=1 mirrors events to stderr (not stdout)
    if [ "${LOG_TO_STDERR:-0}" = "1" ]; then
        echo -e "$line" >&2
    fi
}

log_error() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo -e "$line" >> "$ERROR_LOG_FILE"
    _log_push_event "ERROR: $1"
    echo -e "${RED}${line}${NC}" >&2
}

send_telegram() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return 1
    local msg="$1"
    if command -v jq >/dev/null 2>&1; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg c "$TELEGRAM_CHAT_ID" --arg t "$msg" '{chat_id: $c, text: $t}')" > /dev/null
    else
        msg=$(echo "$msg" | sed 's/\\/\\\\/g' | awk '{printf "%s\\n", $0}' ORS='')
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": \"${msg}\"}" > /dev/null
    fi
}

# Telegram style: 🍏 LONG, 🍎 SHORT, 🥳 TP fill (profit), 😢 SL fill (loss), 🤖 bot lifecycle
telegram_emoji_position() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        long) printf '%s' '🍏' ;;
        short) printf '%s' '🍎' ;;
        *) printf '%s' '🤖' ;;
    esac
}

send_telegram_bot() {
    send_telegram "🤖 $*"
}

send_telegram_position() {
    local direction="$1"
    shift
    send_telegram "$(telegram_emoji_position "$direction") $*"
}

send_telegram_tp() {
    send_telegram "🥳 $*"
}

send_telegram_sl() {
    send_telegram "😢 $*"
}

# Safe division for bc (avoids "Divide by zero" on stderr)
bc_safe_div() {
    local numerator="$1"
    local denominator="$2"
    if [ -z "$denominator" ] || ! (( $(echo "$denominator > 0" | bc -l 2>/dev/null) )); then
        echo "0"
        return 0
    fi
    echo "scale=8; $numerator / $denominator" | bc -l 2>/dev/null || echo "0"
}

# ============================================
# CHECK POSITION VIA BINANCE API
# ============================================

check_open_position() {
    local symbol="$1"

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        if [ "$(ob_get ACTIVE "$symbol")" = "true" ]; then
            local elapsed=$(($(date +%s) - $(ob_get ACTIVE_TS "$symbol")))
            if [ $elapsed -lt $ORDER_COOLDOWN_SECONDS ]; then
                echo "active"
                return 0
            fi
            ob_set ACTIVE "$symbol" "false"
        fi
        echo "none"
        return 1
    fi

    if declare -f futures_has_open_position >/dev/null 2>&1 && futures_has_open_position "$symbol"; then
        echo "active"
        return 0
    fi

    if declare -f futures_has_open_limit_same_side >/dev/null 2>&1; then
        if futures_has_open_limit_same_side "$symbol" "LONG" \
            || futures_has_open_limit_same_side "$symbol" "SHORT"; then
            echo "active"
            return 0
        fi
    fi

    if declare -f futures_has_limit_at_price >/dev/null 2>&1; then
        local direction
        direction=$(ob_get POS_DIR "$symbol")
        if [ -n "$direction" ] && [ "$direction" != "0" ] \
            && futures_has_limit_at_price "$symbol" "$direction" "$(ob_get LAST_ENTRY "$symbol")"; then
            echo "active"
            return 0
        fi
    fi

    echo "none"
    return 1
}

# ============================================
# SET LEVERAGE
# ============================================

set_leverage() {
    local symbol="$1"
    
    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    
    local timestamp
    timestamp=$(binance_timestamp_ms)
    local query_string="symbol=$symbol&leverage=$LEVERAGE&timestamp=$timestamp&recvWindow=5000"
    local signature
    signature=$(echo -n "$query_string" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | awk '{print $2}')
    
    curl -s -X POST "https://fapi.binance.com/fapi/v1/leverage" \
        -H "X-MBX-APIKEY: $BINANCE_API_KEY" \
        -d "$query_string&signature=$signature" > /dev/null 2>&1
}

# ============================================
# CALCULATE QUANTITY
# ============================================

calculate_quantity() {
    local symbol="$1"
    local entry_price="$2"
    
    if [ -z "$entry_price" ] || ! (( $(echo "$entry_price > 0" | bc -l 2>/dev/null) )); then
        echo "0.001"
        return 0
    fi
    
    local raw_quantity
    raw_quantity=$(bc_safe_div "$POSITION_SIZE_USDT" "$entry_price")
    round_qty_for_symbol "$symbol" "$raw_quantity"
}

# ============================================
# SEND ORDER TO BINANCE REST
# ============================================

send_order_binance_rest() {
    local symbol="$1" direction="$2" entry="$3" sl="$4" tp="$5"
    
    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        log_error "Binance API keys not configured"
        return 1
    fi
    
    local quantity vol_usdt
    quantity=$(calculate_quantity "$symbol" "$entry")
    if declare -f format_position_volume_usdt >/dev/null 2>&1; then
        vol_usdt=$(format_position_volume_usdt "$symbol" "$entry" "$quantity")
    else
        vol_usdt="${POSITION_SIZE_USDT:-?}"
    fi
    local side="BUY"
    if [ "$direction" = "SHORT" ]; then
        side="SELL"
    fi
    
    set_leverage "$symbol"
    sleep 0.3
    
    local timestamp
    timestamp=$(binance_timestamp_ms)
    local recv_window=5000
    local order_name="OrderBlocks"
    
    local query_string="symbol=$symbol&side=$side&type=LIMIT&timeInForce=GTC&quantity=$quantity&price=$entry&newClientOrderId=$order_name&timestamp=$timestamp&recvWindow=$recv_window"
    if declare -f append_position_side_param >/dev/null 2>&1; then
        query_string=$(append_position_side_param "$direction" "$query_string")
    fi
    local signature
    signature=$(echo -n "$query_string" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | awk '{print $2}')
    
    log "📝 [REST] $symbol $direction | Entry:$entry SL:$sl TP:$tp | Vol:${vol_usdt} USDT"
    
    if [ "$DRY_RUN" = true ]; then
        log "🔍 DRY-RUN: Would execute"
        log_trade "DRY-RUN OPEN $symbol $direction entry=$entry sl=$sl tp=$tp vol_usdt=$vol_usdt mode=REST"
        send_telegram_bot "DRY-RUN: $symbol $direction | Entry $entry"
        return 0
    fi
    
    local response=$(curl -s -X POST "https://fapi.binance.com/fapi/v1/order" \
        -H "X-MBX-APIKEY: $BINANCE_API_KEY" \
        -d "$query_string&signature=$signature")
    
    if echo "$response" | jq -e '.orderId' >/dev/null 2>&1; then
        local order_id
        order_id=$(echo "$response" | jq -r '.orderId' 2>/dev/null)
        log "✅ Order executed: $symbol (orderId $order_id)"
        log_trade "OPEN $symbol $direction entry=$entry sl=$sl tp=$tp vol_usdt=$vol_usdt mode=REST status=ok orderId=$order_id"
        send_telegram_position "$direction" "$symbol futures
LIMIT #OPEN $direction
Entry: $entry | TP: $tp | SL: $sl | Vol: ${vol_usdt} USDT"

        ob_set ACTIVE "$symbol" "true"
        ob_set ACTIVE_TS "$symbol" "$(date +%s)"
        ob_set POS_DIR "$symbol" "$direction"
        ob_set LAST_ENTRY "$symbol" "$entry"
        ob_set LAST_TP "$symbol" "$tp"
        ob_set LAST_SL "$symbol" "$sl"
        ob_set EXIT_NOTIFIED "$symbol" ""

        if declare -f futures_place_sl_tp_after_entry >/dev/null 2>&1; then
            (
                export TRADES_LOG_FILE BOT_LOG_BASE_DIR BINANCE_API_KEY BINANCE_SECRET_KEY
                export DRY_RUN REST_PLACE_SL_TP REST_SL_TP_FILL_WAIT REST_SL_TP_POLL_INTERVAL
                export BINANCE_HEDGE_MODE BINANCE_POSITION_MODE
                futures_place_sl_tp_after_entry "$symbol" "$direction" "$sl" "$tp" "$quantity" "$order_id" log
            ) &
        fi
        return 0
    else
        log_error "Order failed: $response"
        log_trade "FAILED OPEN $symbol $direction entry=$entry sl=$sl tp=$tp vol_usdt=$vol_usdt mode=REST response=$(echo "$response" | tr -d '\n')"
        send_telegram "❌ $symbol futures — ORDER FAILED ($direction)"
        return 1
    fi
}

# ============================================
# FALLBACK: FINANDY
# ============================================

send_order_finandy() {
    local symbol="$1" direction="$2" entry="$3" sl="$4" tp="$5"
    local quantity vol_usdt

    quantity=$(calculate_quantity "$symbol" "$entry")
    if declare -f format_position_volume_usdt >/dev/null 2>&1; then
        vol_usdt=$(format_position_volume_usdt "$symbol" "$entry" "$quantity")
    else
        vol_usdt="${POSITION_SIZE_USDT:-?}"
    fi

    local side="buy" pos_side="long"
    if [ "$direction" = "SHORT" ]; then
        side="sell"
        pos_side="short"
    fi
    
    local order_name="OrderBlocks_${symbol}_${direction}"
    
    local payload=$(cat <<EOF
{
  "name": "$order_name",
  "secret": "$FINANDY_SECRET",
  "symbol": "$symbol",
  "side": "$side",
  "positionSide": "$pos_side",
  "open": {
    "price": "$entry",
    "schedulerMode": "min",
    "scheduleValue": "5"
  },
  "tp": {
    "enabled": true,
    "orders": [{"price": "$tp", "piece": "100.0"}]
  },
  "sl": {"price": "$sl", "enabled": true}
}
EOF
)
    
    log "📝 [FINANDY] $symbol $direction | Entry:$entry SL:$sl TP:$tp | Vol:${vol_usdt} USDT"
    
    if [ "$DRY_RUN" = true ]; then
        log_trade "DRY-RUN OPEN $symbol $direction entry=$entry sl=$sl tp=$tp vol_usdt=$vol_usdt mode=FINANDY"
        return 0
    fi
    
    local response=$(curl -s -X POST "$FINANDY_WEBHOOK" -H "Content-Type: application/json" -d "$payload")
    
    if echo "$response" | jq -e '.code == 200 or .success == true' >/dev/null 2>&1; then
        log "✅ Order executed via Finandy"
        log_trade "OPEN $symbol $direction entry=$entry sl=$sl tp=$tp vol_usdt=$vol_usdt mode=FINANDY status=ok"
        send_telegram_position "$direction" "$symbol futures
#OPEN $direction (Finandy)
Entry: $entry | TP: $tp | SL: $sl | Vol: ${vol_usdt} USDT"
        ob_set ACTIVE "$symbol" "true"
        ob_set ACTIVE_TS "$symbol" "$(date +%s)"
        ob_set POS_DIR "$symbol" "$direction"
        ob_set LAST_ENTRY "$symbol" "$entry"
        ob_set LAST_TP "$symbol" "$tp"
        ob_set LAST_SL "$symbol" "$sl"
        ob_set EXIT_NOTIFIED "$symbol" ""
    else
        log_error "Order failed: $response"
        log_trade "FAILED OPEN $symbol $direction entry=$entry mode=FINANDY response=$(echo "$response" | tr -d '\n')"
    fi
}

# ============================================
# REPLACE STALE ENTRY LIMITS (GTC → cancel + new price)
# ============================================

ob_replace_stale_entry_limits() {
    local symbol="$1"
    local direction="$2"
    local entry="$3"
    local log_fn="${4:-log}"
    local replace_on last_dir last_entry has_pending=false

    case "$(echo "${REPLACE_STALE_LIMITS}" | tr '[:upper:]' '[:lower:]')" in
        false|0|no|off) return 0 ;;
    esac

    if [ "$ORDER_EXECUTION_MODE" != "rest" ]; then
        return 0
    fi

    if declare -f futures_has_open_position >/dev/null 2>&1 \
        && futures_has_open_position "$symbol"; then
        return 0
    fi

    if declare -f futures_has_open_limit_same_side >/dev/null 2>&1; then
        if futures_has_open_limit_same_side "$symbol" "LONG" \
            || futures_has_open_limit_same_side "$symbol" "SHORT"; then
            has_pending=true
        fi
    fi
    [ "$has_pending" = false ] && return 0

    entry=$(round_price_for_symbol "$symbol" "$entry")
    last_dir=$(ob_get POS_DIR "$symbol")
    last_entry=$(ob_get LAST_ENTRY "$symbol")
    if [ -n "$last_entry" ] && [ "$last_entry" != "0" ]; then
        last_entry=$(round_price_for_symbol "$symbol" "$last_entry")
    fi

    if [ "$direction" = "$last_dir" ] && declare -f futures_has_limit_at_price >/dev/null 2>&1 \
        && futures_has_limit_at_price "$symbol" "$direction" "$entry"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: entry limit already at $entry ($direction)"
        return 2
    fi

    if [ "$DRY_RUN" = true ]; then
        [ -n "$log_fn" ] && $log_fn "🔍 DRY-RUN: Would replace stale limits on $symbol → $direction @ $entry (was ${last_dir:-?} @ ${last_entry:-?})"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "DRY-RUN_REPLACE_LIMIT $symbol $direction entry=$entry prev_dir=${last_dir:-} prev_entry=${last_entry:-}"
        fi
        return 0
    fi

    if declare -f futures_cancel_open_entry_limits >/dev/null 2>&1; then
        futures_cancel_open_entry_limits "$symbol" "" "$log_fn" >/dev/null
    fi

    ob_set ACTIVE "$symbol" "false"
    ob_set POS_DIR "$symbol" ""
    ob_set LAST_ENTRY "$symbol" ""
    ob_set LAST_TP "$symbol" ""
    ob_set LAST_SL "$symbol" ""
    ob_set LOCK_PROFIT_STAGE "$symbol" ""
    [ -n "$log_fn" ] && $log_fn "🔄 $symbol: new $direction @ $entry — replaced unfilled entry limit(s)"
    return 0
}

# ============================================
# DISPATCH ORDER
# ============================================

send_order() {
    local symbol="$1" direction="$2" entry="$3" sl="$4" tp="$5"
    local replace_rc=0
    
    entry=$(round_price_for_symbol "$symbol" "$entry")
    sl=$(round_price_for_symbol "$symbol" "$sl")
    tp=$(round_price_for_symbol "$symbol" "$tp")

    if declare -f clamp_limit_price_for_order >/dev/null 2>&1; then
        local mark clamped_entry
        mark=$(get_futures_mark_price "$symbol")
        clamped_entry=$(clamp_limit_price_for_order "$symbol" "$direction" "$entry" "$mark")
        if [ -n "$clamped_entry" ] && [ "$clamped_entry" != "$entry" ]; then
            log "⚠️ Entry clamped for $symbol $direction: $entry → $clamped_entry (mark=$mark)"
            entry="$clamped_entry"
        fi
    fi
    entry=$(round_price_for_symbol "$symbol" "$entry")
    sl=$(round_price_for_symbol "$symbol" "$sl")
    tp=$(round_price_for_symbol "$symbol" "$tp")

    replace_rc=0
    ob_replace_stale_entry_limits "$symbol" "$direction" "$entry" log || replace_rc=$?
    if [ "$replace_rc" -eq 2 ]; then
        log_trade "SKIP_ORDER $symbol $direction entry=$entry reason=limit_already_at_price"
        log "⏸️ Limit already at $entry — skipping ($symbol)"
        return 0
    fi
    
    if declare -f can_place_new_order >/dev/null 2>&1; then
        if ! can_place_new_order "$symbol" "$direction" "$entry" log; then
            log_trade "SKIP_ORDER $symbol $direction entry=$entry reason=guard_blocked"
            log "⏸️ Order skipped (position or duplicate limit) — $symbol"
            return 0
        fi
    else
        local position_status
        position_status=$(check_open_position "$symbol")
        if [ "$position_status" = "active" ]; then
            log "⏸️ Position already active for $symbol - skipping order"
            log_trade "SKIP_ORDER $symbol $direction entry=$entry reason=position_active"
            log "⏸️ Position already open - skipping ($symbol)"
            return 0
        fi
    fi
    
    case "$ORDER_EXECUTION_MODE" in
        "rest")
            send_order_binance_rest "$symbol" "$direction" "$entry" "$sl" "$tp"
            ;;
        "finandy")
            send_order_finandy "$symbol" "$direction" "$entry" "$sl" "$tp"
            ;;
        *)
            send_order_binance_rest "$symbol" "$direction" "$entry" "$sl" "$tp"
            ;;
    esac
}

# ============================================
# MARKET DATA FUNCTIONS
# ============================================

get_24h_change() {
    local symbol="$1"
    local ticker
    ticker=$(curl -s "https://fapi.binance.com/fapi/v1/ticker/24hr?symbol=$symbol" 2>/dev/null)
    echo "$ticker" | jq -r '.priceChangePercent // 0' 2>/dev/null
}

# ============================================
# GLOBAL VARIABLES FOR OB DATA
# ============================================

declare -a SYMBOL_ARRAY
CURRENT_INDEX=0
NUM_SYMBOLS=0
LAST_CYCLE_TIME=0

show_usage() {
    echo "Usage: $(basename "$0") [options] [SYMBOL]"
    echo ""
    echo "Options:"
    echo "  -d, --dry-run    Do not send orders"
    echo "  -h, --help       Show this help"
    echo ""
    echo "Arguments:"
    echo "  SYMBOL           Monitor only this pair (e.g. BCHUSDT). Overrides SYMBOLS."
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")"
    echo "  $(basename "$0") BCHUSDT"
    echo "  $(basename "$0") --dry-run BCHUSDT"
    echo ""
    echo "Env: ALT_SCREEN=0  disable alternate screen (append log instead)"
}

if [ ! -f "$SCRIPT_DIR/lib/cli_symbols.sh" ]; then
    echo "❌ Error: lib/cli_symbols.sh not found in $SCRIPT_DIR/lib/"
    exit 1
fi
# shellcheck source=lib/cli_symbols.sh
source "$SCRIPT_DIR/lib/cli_symbols.sh"
parse_cli_args "$@"
init_symbol_list

# ============================================
# ANALYZE ORDER BOOK
# ============================================

analyze_order_book() {
    local symbol="$1"
    local bids="$2"
    local asks="$3"
    
    ob_set BID "$symbol" "$(echo "$bids" | jq -r '.[0][0] // "0"' 2>/dev/null)"
    ob_set ASK "$symbol" "$(echo "$asks" | jq -r '.[0][0] // "0"' 2>/dev/null)"
    
    # Find support (strongest bid wall)
    local max_bid_vol=0
    local support="0"
    local bid_count=$(echo "$bids" | jq length 2>/dev/null)
    
    for i in $(seq 0 $((bid_count - 1))); do
        local price=$(echo "$bids" | jq -r ".[$i][0]" 2>/dev/null)
        local vol=$(echo "$bids" | jq -r ".[$i][1]" 2>/dev/null)
        if [ -n "$vol" ] && [ "$vol" != "null" ] && [ -n "$price" ] && [ "$price" != "null" ]; then
            if (( $(echo "$vol > $max_bid_vol" | bc -l 2>/dev/null) )); then
                max_bid_vol=$vol
                support=$price
            fi
        fi
    done
    
    # Find resistance (strongest ask wall)
    local max_ask_vol=0
    local resistance="0"
    local ask_count=$(echo "$asks" | jq length 2>/dev/null)
    
    for i in $(seq 0 $((ask_count - 1))); do
        local price=$(echo "$asks" | jq -r ".[$i][0]" 2>/dev/null)
        local vol=$(echo "$asks" | jq -r ".[$i][1]" 2>/dev/null)
        if [ -n "$vol" ] && [ "$vol" != "null" ] && [ -n "$price" ] && [ "$price" != "null" ]; then
            if (( $(echo "$vol > $max_ask_vol" | bc -l 2>/dev/null) )); then
                max_ask_vol=$vol
                resistance=$price
            fi
        fi
    done
    
    if declare -f ob_set_secondary_walls >/dev/null 2>&1; then
        ob_set_secondary_walls "$symbol" "$bids" "$asks"
    fi
    if declare -f ob_promote_wall_history >/dev/null 2>&1; then
        ob_promote_wall_history "$symbol" "$support" "$resistance"
    else
        ob_set SUPPORT "$symbol" "$support"
        ob_set RESISTANCE "$symbol" "$resistance"
    fi
}

# REST fallback when WebSocket has not populated a symbol yet
hydrate_missing_symbols() {
    for symbol in "${SYMBOL_ARRAY[@]}"; do
        local price
        price=$(ob_get PRICE "$symbol")
        if [ -n "$price" ] && [ "$price" != "0" ] && [ "$price" != "null" ]; then
            continue
        fi
        local depth=$(curl -s "https://fapi.binance.com/fapi/v1/depth?symbol=${symbol}&limit=${DEPTH}" 2>/dev/null)
        [ -z "$depth" ] && continue
        local bids=$(echo "$depth" | jq -c '.bids // []' 2>/dev/null)
        local asks=$(echo "$depth" | jq -c '.asks // []' 2>/dev/null)
        if [ -n "$bids" ] && [ -n "$asks" ] && [ "$bids" != "[]" ]; then
            analyze_order_book "$symbol" "$bids" "$asks"
            ob_set PRICE "$symbol" "$(echo "$depth" | jq -r '.bids[0][0] // 0' 2>/dev/null)"
        fi
    done
}

# ============================================
# DETERMINE SIGNAL (with position check)
# ============================================

determine_signal() {
    local symbol="$1"
    local current_price="$2"
    local change_24h="$3"
    
    # Block when any significant position exists (both legs in hedge mode)
    if declare -f futures_has_open_position >/dev/null 2>&1 \
        && futures_has_open_position "$symbol"; then
        echo "NEUTRAL|0|0|Position already open"
        return
    fi

    if declare -f futures_has_conflicting_entry_limits >/dev/null 2>&1 \
        && futures_has_conflicting_entry_limits "$symbol"; then
        echo "NEUTRAL|0|0|Conflicting entry limits"
        return
    fi

    local replace_stale=false
    case "$(echo "${REPLACE_STALE_LIMITS}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) replace_stale=true ;;
    esac
    if [ "$replace_stale" != true ]; then
        local position_status
        position_status=$(check_open_position "$symbol")
        if [ "$position_status" = "active" ]; then
            echo "NEUTRAL|0|0|Pending limit or position"
            return
        fi
    fi
    
    local support resistance best_bid best_ask
    support=$(ob_get SUPPORT "$symbol")
    resistance=$(ob_get RESISTANCE "$symbol")
    best_bid=$(ob_get BID "$symbol")
    best_ask=$(ob_get ASK "$symbol")
    
    local signal="NEUTRAL"
    local confidence=0
    local entry="$current_price"
    local reasons=""
    
    # Strategy 1: Order Book based (requires valid price and range)
    if [ -n "$current_price" ] && (( $(echo "$current_price > 0" | bc -l 2>/dev/null) )) \
        && [ "$support" != "0" ] && [ "$support" != "null" ] \
        && [ "$resistance" != "0" ] && [ "$resistance" != "null" ]; then
        local range=$(echo "$resistance - $support" | bc -l 2>/dev/null)
        
        if [ -n "$range" ] && (( $(echo "$range > 0" | bc -l 2>/dev/null) )); then
            local position=$(bc_safe_div "($current_price - $support) * 100" "$range")
            
            if [ -n "$position" ] && (( $(echo "$position < 25" | bc -l 2>/dev/null) )); then
                signal="LONG"
                confidence=65
                entry=$(echo "$support * 1.001" | bc -l 2>/dev/null)
                if [ -n "$best_bid" ] && (( $(echo "$best_bid > 0" | bc -l 2>/dev/null) )) \
                    && (( $(echo "$entry > $best_bid" | bc -l 2>/dev/null) )); then
                    entry="$best_bid"
                fi
                entry=$(round_price_for_symbol "$symbol" "$entry")
                reasons="OB: near support"
                
                if (( $(echo "$change_24h < -3" | bc -l 2>/dev/null) )); then
                    confidence=$((confidence + 15))
                    reasons="$reasons + reversal"
                fi
                
            elif [ -n "$position" ] && (( $(echo "$position > 75" | bc -l 2>/dev/null) )); then
                signal="SHORT"
                confidence=65
                entry=$(echo "$resistance * 0.999" | bc -l 2>/dev/null)
                if [ -n "$best_ask" ] && (( $(echo "$best_ask > 0" | bc -l 2>/dev/null) )) \
                    && (( $(echo "$entry < $best_ask" | bc -l 2>/dev/null) )); then
                    entry="$best_ask"
                fi
                entry=$(round_price_for_symbol "$symbol" "$entry")
                reasons="OB: near resistance"
                
                if (( $(echo "$change_24h > 3" | bc -l 2>/dev/null) )); then
                    confidence=$((confidence + 15))
                    reasons="$reasons + reversal"
                fi
            fi
        fi
    fi
    
    # Strategy 2: Fallback based on 24h change (needs live price)
    if [ "$signal" = "NEUTRAL" ] && [ -n "$current_price" ] \
        && (( $(echo "$current_price > 0" | bc -l 2>/dev/null) )); then
        if (( $(echo "$change_24h > 5" | bc -l 2>/dev/null) )); then
            signal="SHORT"
            confidence=50
            entry=$(round_price_for_symbol "$symbol" $(echo "$current_price * 0.998" | bc -l))
            reasons="24h extreme gain (+${change_24h}%)"
        elif (( $(echo "$change_24h < -5" | bc -l 2>/dev/null) )); then
            signal="LONG"
            confidence=50
            entry=$(round_price_for_symbol "$symbol" $(echo "$current_price * 1.002" | bc -l))
            reasons="24h extreme loss (${change_24h}%)"
        elif (( $(echo "$change_24h > 2" | bc -l 2>/dev/null) )); then
            signal="LONG"
            confidence=40
            entry=$(round_price_for_symbol "$symbol" $(echo "$current_price * 1.001" | bc -l))
            reasons="uptrend (+${change_24h}%)"
        elif (( $(echo "$change_24h < -2" | bc -l 2>/dev/null) )); then
            signal="SHORT"
            confidence=40
            entry=$(round_price_for_symbol "$symbol" $(echo "$current_price * 0.999" | bc -l))
            reasons="downtrend (${change_24h}%)"
        fi
    fi
    
    entry=$(round_price_for_symbol "$symbol" "$entry")
    echo "$signal|$confidence|$entry|$reasons"
}

# ============================================
# CALCULATE TP/SL
# ============================================

calculate_tp_sl() {
    local entry="$1" direction="$2" change_24h="$3" spread="$4" symbol="$5"
    
    local sl_pct="$SL_PERCENT"
    local tp_pct="$TP_PERCENT"
    
    if [ -z "$entry" ] || ! (( $(echo "$entry > 0" | bc -l 2>/dev/null) )); then
        echo "0|0|$sl_pct|$tp_pct"
        return 0
    fi

    if declare -f ob_tp_sl_mode_is_grid >/dev/null 2>&1 \
        && ob_tp_sl_mode_is_grid \
        && declare -f ob_freeze_signal_grid >/dev/null 2>&1 \
        && declare -f ob_calculate_grid_tp_sl >/dev/null 2>&1; then
        ob_freeze_signal_grid "$symbol" "$direction"
        local grid_data grid_sl grid_tp grid_note
        grid_data=$(ob_calculate_grid_tp_sl "$entry" "$direction" "$symbol")
        grid_sl=$(echo "$grid_data" | cut -d'|' -f1)
        grid_tp=$(echo "$grid_data" | cut -d'|' -f2)
        grid_note=$(echo "$grid_data" | cut -d'|' -f3-)
        if [ -n "$grid_sl" ] && [ "$grid_sl" != "0" ] \
            && [ -n "$grid_tp" ] && [ "$grid_tp" != "0" ]; then
            echo "$grid_sl|$grid_tp|grid|$grid_note"
            return 0
        fi
    fi
    
    local abs_change=$(echo "$change_24h" | tr -d '-')
    if (( $(echo "$abs_change >= $VOLATILE_THRESHOLD" | bc -l 2>/dev/null) )); then
        sl_pct="$SL_VOLATILE_MIN"
        tp_pct="$TP_VOLATILE_MIN"
    fi
    
    if [ -n "$spread" ] && [ -n "$entry" ] \
        && (( $(echo "$spread > 0 && $entry > 0" | bc -l 2>/dev/null) )); then
        local min_sl=$(echo "$spread * $MIN_SL_SPREAD_MULT" | bc -l 2>/dev/null)
        local min_sl_pct=$(bc_safe_div "$min_sl * 100" "$entry")
        if [ -n "$min_sl_pct" ] && (( $(echo "$min_sl_pct > $sl_pct" | bc -l 2>/dev/null) )); then
            sl_pct="$min_sl_pct"
        fi
    fi
    
    local sl=""
    local tp=""
    
    if [ "$direction" = "LONG" ]; then
        sl=$(echo "$entry * (1 - $sl_pct/100)" | bc -l)
        tp=$(echo "$entry * (1 + $tp_pct/100)" | bc -l)
    else
        sl=$(echo "$entry * (1 + $sl_pct/100)" | bc -l)
        tp=$(echo "$entry * (1 - $tp_pct/100)" | bc -l)
    fi
    
    if [ -n "$symbol" ]; then
        sl=$(round_price_for_symbol "$symbol" "$sl")
        tp=$(round_price_for_symbol "$symbol" "$tp")
    fi
    
    echo "$sl|$tp|$sl_pct|$tp_pct"
}

# ============================================
# PROCESS WEBSOCKET
# ============================================

process_message() {
    local msg="$1"
    local stream_symbol="${2:-}"
    local symbol
    symbol=$(echo "$msg" | jq -r '.s // empty' 2>/dev/null)
    if [ -z "$symbol" ] && [ -n "$stream_symbol" ]; then
        symbol="$stream_symbol"
    fi
    
    [ -z "$symbol" ] && return
    
    local bids=$(echo "$msg" | jq -c '.b' 2>/dev/null)
    local asks=$(echo "$msg" | jq -c '.a' 2>/dev/null)
    
    if [ -n "$bids" ] && [ -n "$asks" ]; then
        analyze_order_book "$symbol" "$bids" "$asks"
        ob_set PRICE "$symbol" "$(echo "$msg" | jq -r '.b[0][0] // .a[0][0]' 2>/dev/null)"
    fi
}

# ============================================
# UPDATE 24H CHANGES
# ============================================

update_24h_changes() {
    for symbol in "${SYMBOL_ARRAY[@]}"; do
        ob_set CHANGE24 "$symbol" "$(get_24h_change "$symbol")"
    done
}

# ============================================
# DISPLAY AND EXECUTE
# ============================================

# Status column: OK | WATCH | NEUTRAL | CLOSE
_dashboard_status_label() {
    local signal="$1" confidence="$2" min_conf="$3" closed="$4"
    if [ "$closed" = "1" ]; then
        printf '%s' "CLOSE"
        return 0
    fi
    if [ "$signal" = "NEUTRAL" ] || [ "$signal" = "NEUT" ]; then
        printf '%s' "NEUTRAL"
        return 0
    fi
    if [ "$confidence" -ge "$min_conf" ] 2>/dev/null; then
        printf '%s' "OK"
        return 0
    fi
    printf '%s' "WATCH"
}

_dashboard_row() {
    printf '%-10s %-8s %-8s %-10s %-11s %-11s %-11s %-8s %-8s %-11s %-11s %-11s %-10s %-11s %-12s' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" "${14}" "${15}"
}

_dashboard_truncate() {
    local text="$1" max="${2:-20}"
    [ -z "$text" ] && printf '%s' "--" && return 0
    if [ "${#text}" -gt "$max" ]; then
        printf '%s' "${text:0:$((max - 1))}…"
    else
        printf '%s' "$text"
    fi
}

# Colored cell (fixed width; ANSI does not break column alignment)
_dashboard_cell() {
    local width="$1" color="$2" value="$3"
    printf '%b%-*s%b' "$color" "$width" "$value" "$NC"
}

# Per-column colors: Status by state, Signal LONG/SHORT, 24h% +/- , Position OPEN/CLOSE
_dashboard_color_row() {
    local symbol="$1" stat="$2" sig="$3" conf="$4" price="$5" bid="$6" ask="$7"
    local ch24="$8" spread="$9" entry="${10}" tp="${11}" sl="${12}" pos="${13}" sup="${14}" res="${15}"
    local stat_c sig_c ch24_c pos_c

    case "$stat" in
        OK) stat_c="$GREEN" ;;
        WATCH) stat_c="$YELLOW" ;;
        OPEN) stat_c="$CYAN" ;;
        CLOSE) stat_c="$MAGENTA" ;;
        *) stat_c="$WHITE" ;;
    esac

    case "$sig" in
        LONG) sig_c="$GREEN" ;;
        SHORT) sig_c="$RED" ;;
        *) sig_c="$WHITE" ;;
    esac

    ch24_c="$WHITE"
    case "$ch24" in
        +*) ch24_c="$GREEN" ;;
        -*) ch24_c="$RED" ;;
    esac

    pos_c="$WHITE"
    case "$pos" in
        OPEN) pos_c="$RED" ;;
        CLOSE) pos_c="$MAGENTA" ;;
    esac

    _dashboard_cell 10 "$WHITE" "$symbol"
    printf ' '
    _dashboard_cell 8 "$stat_c" "$stat"
    printf ' '
    _dashboard_cell 8 "$sig_c" "$sig"
    printf ' '
    _dashboard_cell 10 "$WHITE" "$conf"
    printf ' %-11s %-11s %-11s' "$price" "$bid" "$ask"
    printf ' '
    _dashboard_cell 8 "$ch24_c" "$ch24"
    printf ' %-8s %-11s %-11s %-11s ' "$spread" "$entry" "$tp" "$sl"
    _dashboard_cell 10 "$pos_c" "$pos"
    printf ' %-11s %-12s' "$sup" "$res"
}

draw_and_execute() {
    local mode_label="LIVE"
    [ "$DRY_RUN" = true ] && mode_label="DRY-RUN"
    local -a _dash=()
    local symbol price best_bid best_ask support resistance change spread
    local signal_data signal confidence entry reasons sl tp
    local status_label pos_col closed_flag change_disp signal_dir reason_short
    local evt line
    local -a _dash_notes=()

    # --- Phase 1: update state, trade, build rows (no terminal output) ---
    for symbol in "${SYMBOL_ARRAY[@]}"; do
        price=$(ob_get PRICE "$symbol")
        best_bid=$(ob_get BID "$symbol")
        best_ask=$(ob_get ASK "$symbol")
        support=$(ob_get SUPPORT "$symbol")
        resistance=$(ob_get RESISTANCE "$symbol")
        change=$(ob_get CHANGE24 "$symbol")

        spread=0
        if [ "$best_bid" != "0" ] && [ "$best_ask" != "0" ] && [ "$best_bid" != "null" ] && [ "$best_ask" != "null" ]; then
            spread=$(echo "$best_ask - $best_bid" | bc -l 2>/dev/null)
        fi

        if declare -f sync_symbol_position_flags >/dev/null 2>&1; then
            sync_symbol_position_flags "$symbol"
        fi

        pos_col="--"
        if [ "$(ob_get ACTIVE "$symbol")" = "true" ]; then
            pos_col="OPEN"
        elif declare -f futures_has_open_position >/dev/null 2>&1 \
            && futures_has_open_position "$symbol"; then
            pos_col="OPEN"
        fi

        closed_flag=0
        if declare -f try_close_on_opposite_ob >/dev/null 2>&1 \
            && try_close_on_opposite_ob "$symbol" "$price" "$ZONE_UPPER_PCT" "$ZONE_LOWER_PCT" log; then
            closed_flag=1
            pos_col="CLOSE"
            log "🔒 $symbol — closed (or closing) on opposite OB touch"
        fi

        signal_data=$(determine_signal "$symbol" "$price" "$change")
        signal=$(echo "$signal_data" | cut -d'|' -f1)
        confidence=$(echo "$signal_data" | cut -d'|' -f2)
        entry=$(echo "$signal_data" | cut -d'|' -f3)
        reasons=$(echo "$signal_data" | cut -d'|' -f4)

        sl="--"
        tp="--"
        if [ "$signal" != "NEUTRAL" ] && [ -n "$entry" ] && (( $(echo "$entry > 0" | bc -l 2>/dev/null) )); then
            local tp_sl_data
            tp_sl_data=$(calculate_tp_sl "$entry" "$signal" "$change" "$spread" "$symbol")
            sl=$(echo "$tp_sl_data" | cut -d'|' -f1)
            tp=$(echo "$tp_sl_data" | cut -d'|' -f2)
        else
            entry="--"
        fi

        signal_dir="$signal"
        if [ "$pos_col" = "OPEN" ] || [ "$pos_col" = "CLOSE" ]; then
            local stored_entry stored_tp stored_sl stored_dir
            stored_entry=$(ob_get LAST_ENTRY "$symbol")
            stored_tp=$(ob_get LAST_TP "$symbol")
            stored_sl=$(ob_get LAST_SL "$symbol")
            stored_dir=$(ob_get POS_DIR "$symbol")
            if [ -n "$stored_dir" ] && [ "$stored_dir" != "0" ]; then
                signal_dir="$stored_dir"
            fi
            if [ -n "$stored_entry" ] && [ "$stored_entry" != "0" ]; then
                entry="$stored_entry"
            fi
            if [ -n "$stored_tp" ] && [ "$stored_tp" != "0" ]; then
                tp="$stored_tp"
            fi
            if [ -n "$stored_sl" ] && [ "$stored_sl" != "0" ]; then
                sl="$stored_sl"
            fi
        fi

        status_label=$(_dashboard_status_label "$signal" "$confidence" "$MIN_CONFIDENCE" "$closed_flag")
        if [ "$pos_col" = "OPEN" ]; then
            status_label="OPEN"
        fi

        change_disp="$change"
        if [ -n "$change" ] && [ "$change" != "0" ]; then
            case "$change" in
                *%*) ;;
                -*) change_disp="${change}%" ;;
                *) change_disp="+${change}%" ;;
            esac
        fi

        if [ "$signal_dir" != "NEUTRAL" ] && [ "$confidence" -ge "$MIN_CONFIDENCE" ] && [ "$closed_flag" -eq 0 ]; then
            local grid_extra=""
            if declare -f ob_tp_sl_mode_is_grid >/dev/null 2>&1 && ob_tp_sl_mode_is_grid; then
                grid_extra=" R0=$(ob_get SIGNAL_R0 "$symbol") R1=$(ob_get SIGNAL_R1 "$symbol") R2=$(ob_get SIGNAL_R2 "$symbol") S0=$(ob_get SIGNAL_S0 "$symbol") S1=$(ob_get SIGNAL_S1 "$symbol")"
            fi
            log_trade "SIGNAL $symbol $signal_dir conf=${confidence}% entry=$entry tp=$tp sl=$sl | $reasons${grid_extra}"
            if [ "$DRY_RUN" = true ]; then
                log_trade "DRY-RUN_SIGNAL $symbol $signal_dir entry=$entry (no order sent)"
            else
                send_order "$symbol" "$signal_dir" "$entry" "$sl" "$tp"
            fi
        elif [ "$signal_dir" != "NEUTRAL" ]; then
            log_trade "WATCH $symbol $signal_dir conf=${confidence}% need=${MIN_CONFIDENCE}% entry=$entry | $reasons"
        fi

        reason_short=$(_dashboard_truncate "$reasons" 18)
        _dash+=("$(_dashboard_color_row "$symbol" "$status_label" "$signal_dir" "$confidence" \
            "$price" "$best_bid" "$best_ask" "$change_disp" "$spread" "$entry" "$tp" "$sl" "$pos_col" "$support" "$resistance")")

        if [ "$signal_dir" != "NEUTRAL" ] && [ -n "$reasons" ] && [ "$reasons" != "0" ]; then
            _dash_notes+=("${YELLOW}  ▶ ${symbol}${NC} ${reasons}")
        fi
    done

    # --- Phase 2: single screen draw ---
    _dash=("${CYAN}${BOLD}  Order Blocks Bot v5.0 — $(date '+%Y-%m-%d %H:%M:%S')  |  ${mode_label}  |  conf≥${MIN_CONFIDENCE}%  |  cooldown ${ORDER_COOLDOWN_SECONDS}s${NC}" "" \
        "${CYAN}$(_dashboard_row 'Symbol' 'Status' 'Signal' 'Confidence' 'Price' 'Bid' 'Ask' '24h%' 'Spread' 'Entry' 'TP' 'SL' 'Position' 'Support' 'Resistance')${NC}" \
        "$(_dashboard_row '──────────' '────────' '────────' '──────────' '───────────' '───────────' '───────────' '────────' '────────' '───────────' '───────────' '───────────' '──────────' '───────────' '────────────')" \
        "${_dash[@]}")

    if [ "${#_dash_notes[@]}" -gt 0 ]; then
        _dash+=("" "${CYAN}Signals:${NC}")
        _dash+=("${_dash_notes[@]}")
    fi

    _dash+=("" "${YELLOW}Logs: tail -f logs/bot.log  |  trades: logs/trades.log  |  cycle 5s  |  Ctrl+C exit${NC}")

    if [ "${#_LOG_RING[@]}" -gt 0 ]; then
        _dash+=("${CYAN}Recent:${NC}")
        for evt in "${_LOG_RING[@]}"; do
            line="$evt"
            [ "${#line}" -gt 88 ] && line="${line:0:85}..."
            _dash+=("  $line")
        done
    fi

    dashboard_flush "${_dash[@]}"
}

# ============================================
# WEBSOCKET SETUP
# ============================================

build_ws_url() {
    local streams=""
    local first=true
    for symbol in "${SYMBOL_ARRAY[@]}"; do
        local lower=$(echo "$symbol" | tr '[:upper:]' '[:lower:]')
        if [ "$first" = true ]; then
            streams="${lower}@depth${DEPTH}@${SPEED}"
            first=false
        else
            streams="${streams}/${lower}@depth${DEPTH}@${SPEED}"
        fi
    done
    echo "wss://fstream.binance.com/stream?streams=${streams}"
}

run_cycle() {
    local current_time=$(date +%s)
    if (( current_time - LAST_CYCLE_TIME < 5 )); then
        return
    fi
    LAST_CYCLE_TIME=$current_time

    if [ -n "${TRADES_LOG_HEARTBEAT_SECONDS:-}" ] \
        && (( current_time - LAST_TRADES_HEARTBEAT >= TRADES_LOG_HEARTBEAT_SECONDS )); then
        LAST_TRADES_HEARTBEAT=$current_time
        log_trade "HEARTBEAT bot=order_blocks symbols=${NUM_SYMBOLS} file=${TRADES_LOG_FILE}"
    fi
    
    update_24h_changes
    hydrate_missing_symbols

    if declare -f futures_try_lock_profit >/dev/null 2>&1; then
        local _sym _lp_price
        for _sym in "${SYMBOL_ARRAY[@]}"; do
            _lp_price=$(ob_get PRICE "$_sym")
            if [ -z "$_lp_price" ] || [ "$_lp_price" = "0" ]; then
                _lp_price=$(ob_get ASK "$_sym")
            fi
            if [ -z "$_lp_price" ] || [ "$_lp_price" = "0" ]; then
                _lp_price=$(ob_get BID "$_sym")
            fi
            futures_try_lock_profit "$_sym" "$_lp_price" log
        done
    fi

    draw_and_execute
}

connect_websocket() {
    local ws_url=$(build_ws_url)
    
    log "🔌 Connecting to Binance WebSocket..."
    log "   URL: $ws_url"
    
    if ! command -v websocat &> /dev/null; then
        log_error "websocat not installed. Run: brew install websocat"
        exit 1
    fi
    
    while true; do
        # Process substitution (not pipe) so declare -A state persists in this shell
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local stream stream_sym data
                stream=$(echo "$line" | jq -r '.stream // empty' 2>/dev/null)
                stream_sym=$(ob_symbol_from_stream "$stream")
                data=$(echo "$line" | jq -c '.data // empty' 2>/dev/null)
                if [ -n "$data" ] && [ "$data" != "null" ]; then
                    process_message "$data" "$stream_sym"
                fi
                run_cycle
            fi
        done < <(websocat --text "$ws_url" 2>/dev/null)
        
        log_error "Connection lost. Reconnecting in 5 seconds..."
        sleep 5
    done
}

# ============================================
# MAIN
# ============================================

main() {
    echo -e "${BLUE}${BOLD}"
    echo "╔════════════════════════════════════════════════════════════════════════════════════╗"
    echo "║         Order Blocks Bot v5.0 — Binance WebSocket (main.sh)                         ║"
    echo "╚════════════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if declare -f init_bot_logs >/dev/null 2>&1; then
        init_bot_logs "order_blocks v5.0"
    fi
    
    log "🚀 Starting Order Blocks Bot v5.0"
    log "📋 Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE")"
    if [ "$SINGLE_SYMBOL_MODE" = true ]; then
        log "📊 Symbol: ${SYMBOL_ARRAY[0]} (single-symbol mode)"
    else
        log "📊 Symbols: ${SYMBOLS}"
    fi
    log "🎯 Min Confidence: ${MIN_CONFIDENCE}%"
    log "📐 TP/SL mode: ${TP_SL_MODE} (ob_grid: SHORT SL=R1 TP=S0, LONG SL=S1 TP=R0)"
    if declare -f ob_tp_sl_mode_is_grid >/dev/null 2>&1 && ob_tp_sl_mode_is_grid; then
        log "   OB wall shift: ${OB_WALL_SHIFT_PCT}% | buffers SL=${SL_OB_BUFFER_PCT}% TP=${TP_OB_BUFFER_PCT}%"
    fi
    log "🛡️ REST SL/TP after fill: ${REST_PLACE_SL_TP} (wait ${REST_SL_TP_FILL_WAIT}s)"
    log "🔐 Lock profit: ${LOCK_PROFIT_ENABLED} (trigger ${LOCK_PROFIT_BE_PCT}% toward TP → SL at ${LOCK_PROFIT_SL_AT_PCT}% entry→TP)"
    log "⏰ Order Cooldown: ${ORDER_COOLDOWN_SECONDS}s per symbol (local fallback without API)"
    log "🔄 Replace stale entry LIMIT: ${REPLACE_STALE_LIMITS} (REST only; max 1 cycle / 5s per symbol)"
    log "📁 Log: $LOG_FILE | Errors: $ERROR_LOG_FILE | Trades: $TRADES_LOG_FILE"
    log_trade "READY bot=order_blocks trades_log=${TRADES_LOG_FILE}"
    
    if ! declare -f round_price_for_symbol >/dev/null 2>&1; then
        log_error "round_price_for_symbol missing — check $BINANCE_PRECISION_LIB"
        exit 1
    fi
    
    if init_all_symbol_precision "${SYMBOL_ARRAY[@]}"; then
        log "✅ Binance precision loaded for ${#SYMBOL_ARRAY[@]} symbols (lib/binance_precision.sh)"
    else
        log_error "Could not load exchangeInfo precision"
        exit 1
    fi
    
    if declare -f detect_binance_position_mode >/dev/null 2>&1 && detect_binance_position_mode; then
        if [ "$BINANCE_HEDGE_MODE" = true ]; then
            log "✅ Binance position mode: Hedge (dual) — orders use positionSide"
        else
            log "✅ Binance position mode: One-way — orders without positionSide"
        fi
    else
        log_error "Could not detect position mode (set BINANCE_POSITION_MODE=hedge or oneway in .env)"
    fi

    if declare -f sync_startup_configured_positions >/dev/null 2>&1 \
        && [ -n "$BINANCE_API_KEY" ] && [ -n "$BINANCE_SECRET_KEY" ]; then
        sync_startup_configured_positions log "${SYMBOL_ARRAY[@]}"
        log_trade "STARTUP_SYNC symbols=${SYMBOLS}"
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq not installed. Run: brew install jq"
        exit 1
    fi
    
    if ! command -v websocat &> /dev/null; then
        log_error "websocat not installed. Run: brew install websocat"
        exit 1
    fi
    
    send_telegram_bot "Order Blocks Bot v5.0 started
Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE") | Symbols: ${SYMBOLS} | Cooldown: ${ORDER_COOLDOWN_SECONDS}s"
    
    screen_enable_alt
    connect_websocket
}

trap 'screen_disable_alt; echo -e "\n${YELLOW}👋 Shutting down...${NC}"; send_telegram_bot "Order Blocks Bot stopped"; exit 0' INT
trap 'screen_disable_alt' EXIT

main