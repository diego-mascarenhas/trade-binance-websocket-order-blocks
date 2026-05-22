#!/bin/bash
# Terminal dashboard: alternate screen, full redraw, single flush (no log overlap)

# 1 = alternate screen (default). 0 = append mode (separator each cycle).
TERM_ALT_SCREEN="${ALT_SCREEN:-1}"
_ALT_SCREEN_ACTIVE=false
_DASHBOARD_TOTAL_LINES=0

screen_enable_alt() {
    [ "$TERM_ALT_SCREEN" = "0" ] && return 0
    [ "$_ALT_SCREEN_ACTIVE" = true ] && return 0
    printf '\033[?1049h\033[2J\033[H'
    _ALT_SCREEN_ACTIVE=true
}

screen_disable_alt() {
    [ "$_ALT_SCREEN_ACTIVE" != true ] && return 0
    printf '\033[?1049l'
    _ALT_SCREEN_ACTIVE=false
}

# Full clear + home on each redraw (stable table; logs must not use stdout)
screen_refresh() {
    if [ "$TERM_ALT_SCREEN" = "0" ]; then
        printf '\n\033[36m──────────────── %s ────────────────\033[0m\n' "$(date '+%H:%M:%S')"
        return 0
    fi
    if [ "$_ALT_SCREEN_ACTIVE" = true ]; then
        printf '\033[2J\033[H'
    else
        printf '\033[2J\033[H'
    fi
}

term_ln() {
    printf '%b\033[K\n' "$1"
}

# Print all dashboard lines in one pass (call after building the full table in memory)
dashboard_flush() {
    local line
    screen_refresh
    for line in "$@"; do
        term_ln "$line"
    done
    _DASHBOARD_TOTAL_LINES=$#
}
