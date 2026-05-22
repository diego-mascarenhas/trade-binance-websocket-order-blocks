#!/bin/bash
# Trading window: allowed days + UTC hours (same model as trade-deepseek/deepseek.sh)

_tr_sched_enabled() {
    local flag="${TRADING_SCHEDULE_ENABLED:-true}"
    case "$(echo "$flag" | tr '[:upper:]' '[:lower:]')" in
        false|0|no|off) return 1 ;;
        *) return 0 ;;
    esac
}

# Echo 0-23 (no leading zero)
_tr_sched_current_hour() {
    date -u +%H 2>/dev/null | sed 's/^0//'
}

# Echo 1-7 (Mon=1 … Sun=7)
_tr_sched_current_dow() {
    date -u +%u 2>/dev/null
}

# Echo reason string if blocked; empty if allowed
trading_schedule_block_reason() {
    local start end days day hour

    if ! _tr_sched_enabled; then
        echo ""
        return 0
    fi

    start="${EXECUTION_HOUR_START:-0}"
    end="${EXECUTION_HOUR_END:-23}"
    days="${ALLOWED_DAYS:-1,2,3,4,5,6,7}"

    day=$(_tr_sched_current_dow)
    hour=$(_tr_sched_current_hour)
    [ -z "$hour" ] && hour=0

    if ! echo "$days" | grep -qE "(^|,)[[:space:]]*${day}[[:space:]]*(,|$)"; then
        echo "day_not_allowed dow=${day} allowed=${days}"
        return 0
    fi

    if [ "$hour" -lt "$start" ] 2>/dev/null || [ "$hour" -ge "$end" ] 2>/dev/null; then
        echo "hour_not_allowed hour=${hour}utc window=${start}-${end}utc"
        return 0
    fi

    echo ""
}

# Return 0 if new orders are allowed now
is_trading_time_allowed() {
    local reason
    reason=$(trading_schedule_block_reason)
    [ -z "$reason" ]
}

# One-line summary for startup / dashboard
trading_schedule_summary() {
    if ! _tr_sched_enabled; then
        echo "schedule=off"
        return 0
    fi
    local end_display=$((EXECUTION_HOUR_END - 1))
    [ "$end_display" -lt 0 ] 2>/dev/null && end_display=0
    echo "UTC $(trading_schedule_days_label) hours ${EXECUTION_HOUR_START:-0}-${EXECUTION_HOUR_END:-23} (end exclusive)"
}

trading_schedule_days_label() {
    local days="${ALLOWED_DAYS:-1,2,3,4,5,6,7}"
    local labels="" d name
    for d in $(echo "$days" | tr ',' ' '); do
        d=$(echo "$d" | tr -d '[:space:]')
        case "$d" in
            1) name=Mon ;;
            2) name=Tue ;;
            3) name=Wed ;;
            4) name=Thu ;;
            5) name=Fri ;;
            6) name=Sat ;;
            7) name=Sun ;;
            *) name="?" ;;
        esac
        if [ -n "$labels" ]; then
            labels="${labels},${name}"
        else
            labels="$name"
        fi
    done
    echo "$labels"
}
