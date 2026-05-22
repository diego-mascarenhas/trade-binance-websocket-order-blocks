#!/bin/bash
# Reduce terminal flicker: alternate screen + cursor-home refresh (not full clear)

# 1 = alternate screen (default, less flicker). 0 = append updates with a separator line.
TERM_ALT_SCREEN="${ALT_SCREEN:-1}"
_ALT_SCREEN_ACTIVE=false

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

# Call at the start of each dashboard redraw (replaces clear)
screen_refresh() {
    if [ "$TERM_ALT_SCREEN" = "0" ]; then
        printf '\n\033[36m──────────────── %s ────────────────\033[0m\n' "$(date '+%H:%M:%S')"
        return 0
    fi
    if [ "$_ALT_SCREEN_ACTIVE" = true ]; then
        printf '\033[H\033[J'
    else
        printf '\033[2J\033[H'
    fi
}
