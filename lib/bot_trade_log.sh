#!/bin/bash
# Append trade events to TRADES_LOG_FILE (set by main.sh)

# Resolve relative log paths (subshells / cron may change cwd)
_bot_trade_log_resolve_path() {
    local p="$1"
    local base="${BOT_LOG_BASE_DIR:-}"
    if [ -z "$p" ]; then
        echo ""
        return 0
    fi
    if [[ "$p" = /* ]]; then
        echo "$p"
        return 0
    fi
    if [ -n "$base" ]; then
        echo "${base%/}/$p"
    else
        echo "$(pwd)/$p"
    fi
}

log_trade() {
    local log_file="${TRADES_LOG_FILE:-}"
    if [ -z "$log_file" ]; then
        return 0
    fi
    log_file=$(_bot_trade_log_resolve_path "$log_file")
    local dir
    dir=$(dirname "$log_file")
    [ -n "$dir" ] && [ "$dir" != "." ] && mkdir -p "$dir" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$log_file"
}

# Create log files and write startup line (call from main() before trading)
init_bot_logs() {
    local bot_name="${1:-bot}"
    local ts line mode

    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "${DRY_RUN:-false}" = true ]; then
        mode="DRY-RUN"
    else
        mode="LIVE"
    fi
    line="[$ts] === $bot_name started | mode=$mode ==="

    local f dir
    for f in "${LOG_FILE:-}" "${ERROR_LOG_FILE:-}" "${TRADES_LOG_FILE:-}"; do
        [ -z "$f" ] && continue
        dir=$(dirname "$f")
        [ -n "$dir" ] && [ "$dir" != "." ] && mkdir -p "$dir" 2>/dev/null
        echo "$line" >> "$f"
    done

    if [ -n "${TRADES_LOG_FILE:-}" ]; then
        log_trade "START bot=$bot_name mode=$mode"
    fi
}
