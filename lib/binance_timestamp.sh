#!/bin/bash
# Portable millisecond timestamp for Binance signed REST (macOS + Linux)

binance_timestamp_ms() {
    local ts
    ts=$(date +%s%3N 2>/dev/null || true)
    # GNU date: 13-digit ms. macOS date often appends literal "3N" → invalid.
    if [[ "$ts" =~ ^[0-9]{13}$ ]]; then
        echo "$ts"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time() * 1000))'
        return 0
    fi
    echo $(($(date +%s) * 1000))
}
