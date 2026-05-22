#!/bin/bash
# CLI: --dry-run, --help, optional single SYMBOL (used by main.sh)

parse_cli_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-d)
                DRY_RUN=true
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                echo "❌ Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [ -n "$SYMBOL_CLI" ]; then
                    echo "❌ Only one SYMBOL argument is allowed (got: $SYMBOL_CLI and $1)"
                    exit 1
                fi
                SYMBOL_CLI=$(echo "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
                ;;
        esac
        shift
    done

    if [ -n "$SYMBOL_CLI" ]; then
        SYMBOLS="$SYMBOL_CLI"
        SINGLE_SYMBOL_MODE=true
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "🔍 DRY-RUN MODE: No orders will be executed"
    fi
}

init_symbol_list() {
    local _sym _i
    IFS=',' read -ra SYMBOL_ARRAY <<< "$SYMBOLS"
    for _i in "${!SYMBOL_ARRAY[@]}"; do
        _sym=$(echo "${SYMBOL_ARRAY[$_i]}" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
        SYMBOL_ARRAY[$_i]="$_sym"
    done
    NUM_SYMBOLS=${#SYMBOL_ARRAY[@]}
    if [ "$NUM_SYMBOLS" -lt 1 ] || [ -z "${SYMBOL_ARRAY[0]}" ]; then
        echo "❌ Error: no symbols configured (SYMBOLS env or SYMBOL argument)"
        exit 1
    fi
    if [ "$NUM_SYMBOLS" -eq 1 ]; then
        SINGLE_SYMBOL_MODE=true
    fi
    CURRENT_INDEX=0
}
