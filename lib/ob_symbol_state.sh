#!/bin/bash
# Per-symbol state without associative arrays (bash 3.2+ / macOS compatible)

_ob_state_key() {
    local field="$1"
    local sym="$2"
    sym=$(echo "$sym" | tr -cd 'A-Za-z0-9_')
    echo "OB_${field}__${sym}"
}

ob_set() {
    local field="$1" sym="$2" val="$3"
    local k
    k=$(_ob_state_key "$field" "$sym")
    printf -v "$k" '%s' "$val"
}

ob_get() {
    local field="$1" sym="$2"
    local k v
    k=$(_ob_state_key "$field" "$sym")
    v="${!k}"
    if [ -n "$v" ]; then
        echo "$v"
    else
        echo "0"
    fi
}

ob_get_default() {
    local field="$1" sym="$2" default="$3"
    local k v
    k=$(_ob_state_key "$field" "$sym")
    v="${!k:-}"
    if [ -n "$v" ]; then
        echo "$v"
    else
        echo "$default"
    fi
}

# Extract ADAUSDT from stream name e.g. adausdt@depth10@500ms
ob_symbol_from_stream() {
    local stream="$1"
    [ -z "$stream" ] && return 1
    echo "$stream" | cut -d'@' -f1 | tr '[:lower:]' '[:upper:]'
}
