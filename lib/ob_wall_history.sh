#!/bin/bash
# Historical order-book walls (R0/R1, S0/S1) and ob_grid TP/SL mode.
# SHORT: SL at R1 (prev resistance), TP at S0 (support). Entry zone ~ R0.
# LONG:  SL at S1 (prev support), TP at R0 (resistance). Entry zone ~ S0.

_ob_wh_bc_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 > b + 0) ? 0 : 1 }'
}

_ob_wh_bc_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 < b + 0) ? 0 : 1 }'
}

_ob_wh_is_positive() {
    [ -n "$1" ] && [ "$1" != "0" ] && [ "$1" != "null" ] && _ob_wh_bc_gt "$1" "0"
}

_ob_wh_price_shift_pct() {
    local old="$1" new="$2"
    if ! _ob_wh_is_positive "$old" || ! _ob_wh_is_positive "$new"; then
        echo ""
        return 0
    fi
    if declare -f bc_safe_div >/dev/null 2>&1; then
        bc_safe_div "($new - $old) * 100" "$old" | tr -d '-'
    else
        echo "scale=8; ($new - $old) * 100 / $old" | bc -l 2>/dev/null | tr -d '-'
    fi
}

_ob_wh_wall_changed() {
    local old="$1" new="$2" threshold_pct="$3"
    if ! _ob_wh_is_positive "$new"; then
        return 1
    fi
    if ! _ob_wh_is_positive "$old"; then
        return 0
    fi
    local diff
    diff=$(_ob_wh_price_shift_pct "$old" "$new")
    [ -z "$diff" ] && return 1
    awk -v d="$diff" -v t="$threshold_pct" 'BEGIN { exit (d + 0 >= t + 0) ? 0 : 1 }'
}

# Top-two volume walls from one side of the book; echoes "second|first".
_ob_wh_top_two_walls() {
    local book="$1"
    local best_vol=0 second_vol=0 best_price="0" second_price="0"
    local count vol price i

    count=$(echo "$book" | jq length 2>/dev/null)
    for i in $(seq 0 $((count - 1))); do
        price=$(echo "$book" | jq -r ".[$i][0]" 2>/dev/null)
        vol=$(echo "$book" | jq -r ".[$i][1]" 2>/dev/null)
        if [ -z "$vol" ] || [ "$vol" = "null" ] || [ -z "$price" ] || [ "$price" = "null" ]; then
            continue
        fi
        if (( $(echo "$vol > $best_vol" | bc -l 2>/dev/null) )); then
            second_vol=$best_vol
            second_price=$best_price
            best_vol=$vol
            best_price=$price
        elif (( $(echo "$vol > $second_vol" | bc -l 2>/dev/null) )); then
            second_vol=$vol
            second_price=$price
        fi
    done
    echo "${second_price}|${best_price}"
}

# 2nd-largest volume wall (R2/S2) when R1 is too close to R0.
ob_set_secondary_walls() {
    local symbol="$1" bids="$2" asks="$3"
    local pair second

    pair=$(_ob_wh_top_two_walls "$bids")
    second=$(echo "$pair" | cut -d'|' -f1)
    if _ob_wh_is_positive "$second"; then
        ob_set SUPPORT2 "$symbol" "$second"
    fi

    pair=$(_ob_wh_top_two_walls "$asks")
    second=$(echo "$pair" | cut -d'|' -f1)
    if _ob_wh_is_positive "$second"; then
        ob_set RESISTANCE2 "$symbol" "$second"
    fi
}

_ob_wh_wall_gap_pct() {
    local a="$1" b="$2"
    if ! _ob_wh_is_positive "$a" || ! _ob_wh_is_positive "$b"; then
        echo ""
        return 0
    fi
    _ob_wh_price_shift_pct "$a" "$b"
}

_ob_wh_max_price() {
    local a="$1" b="$2"
    if _ob_wh_is_positive "$a" && _ob_wh_is_positive "$b"; then
        echo "scale=12; if ($a > $b) $a else $b" | bc -l 2>/dev/null
    elif _ob_wh_is_positive "$a"; then
        echo "$a"
    else
        echo "$b"
    fi
}

_ob_wh_min_price() {
    local a="$1" b="$2"
    if _ob_wh_is_positive "$a" && _ob_wh_is_positive "$b"; then
        echo "scale=12; if ($a < $b) $a else $b" | bc -l 2>/dev/null
    elif _ob_wh_is_positive "$a"; then
        echo "$a"
    else
        echo "$b"
    fi
}

# Widen SL if grid level is too close to entry (SHORT: SL above entry).
_ob_wh_enforce_min_sl_distance() {
    local entry="$1" sl="$2" direction="$3"
    local min_pct="${OB_GRID_MIN_SL_PCT:-}"
    if [ -z "$min_pct" ]; then
        min_pct="${SL_PERCENT:-0.4}"
    fi
    if ! _ob_wh_is_positive "$entry" || ! _ob_wh_is_positive "$sl" || ! _ob_wh_is_positive "$min_pct"; then
        echo "$sl"
        return 0
    fi
    direction=$(echo "$direction" | tr '[:lower:]' '[:upper:]')
    if [ "$direction" = "SHORT" ]; then
        local min_sl dist_pct
        min_sl=$(echo "$entry * (1 + $min_pct/100)" | bc -l 2>/dev/null)
        if _ob_wh_is_positive "$min_sl" && _ob_wh_bc_lt "$sl" "$min_sl"; then
            echo "$min_sl"
            return 0
        fi
        dist_pct=$(_ob_wh_price_shift_pct "$entry" "$sl")
    elif [ "$direction" = "LONG" ]; then
        local min_sl
        min_sl=$(echo "$entry * (1 - $min_pct/100)" | bc -l 2>/dev/null)
        if _ob_wh_is_positive "$min_sl" && _ob_wh_bc_gt "$sl" "$min_sl"; then
            echo "$min_sl"
            return 0
        fi
    fi
    echo "$sl"
}

ob_promote_wall_history() {
    local symbol="$1" new_support="$2" new_resistance="$3"
    local shift_pct="${OB_WALL_SHIFT_PCT:-0.15}"
    local old_support old_resistance

    if ! declare -f ob_get >/dev/null 2>&1; then
        return 0
    fi

    old_resistance=$(ob_get RESISTANCE "$symbol")
    if _ob_wh_wall_changed "$old_resistance" "$new_resistance" "$shift_pct"; then
        if _ob_wh_is_positive "$old_resistance"; then
            ob_set PREV_RESISTANCE "$symbol" "$old_resistance"
        fi
    fi
    if _ob_wh_is_positive "$new_resistance"; then
        ob_set RESISTANCE "$symbol" "$new_resistance"
    fi

    old_support=$(ob_get SUPPORT "$symbol")
    if _ob_wh_wall_changed "$old_support" "$new_support" "$shift_pct"; then
        if _ob_wh_is_positive "$old_support"; then
            ob_set PREV_SUPPORT "$symbol" "$old_support"
        fi
    fi
    if _ob_wh_is_positive "$new_support"; then
        ob_set SUPPORT "$symbol" "$new_support"
    fi
}

ob_freeze_signal_grid() {
    local symbol="$1" direction="$2"

    ob_set SIGNAL_DIR "$symbol" "$direction"
    ob_set SIGNAL_TS "$symbol" "$(date +%s)"
    ob_set SIGNAL_R0 "$symbol" "$(ob_get RESISTANCE "$symbol")"
    ob_set SIGNAL_R1 "$symbol" "$(ob_get PREV_RESISTANCE "$symbol")"
    ob_set SIGNAL_R2 "$symbol" "$(ob_get RESISTANCE2 "$symbol")"
    ob_set SIGNAL_S0 "$symbol" "$(ob_get SUPPORT "$symbol")"
    ob_set SIGNAL_S1 "$symbol" "$(ob_get PREV_SUPPORT "$symbol")"
    ob_set SIGNAL_S2 "$symbol" "$(ob_get SUPPORT2 "$symbol")"
}

ob_tp_sl_mode_is_grid() {
    local mode="${TP_SL_MODE:-percent}"
    mode=$(echo "$mode" | tr '[:upper:]' '[:lower:]')
    case "$mode" in
        ob_grid|grid|ob|walls|structure) return 0 ;;
        *) return 1 ;;
    esac
}

ob_calculate_grid_tp_sl() {
    local entry="$1" direction="$2" symbol="$3"
    local sl="" tp="" note=""
    local r0 r1 r2 s0 s1 s2
    local sl_buf="${SL_OB_BUFFER_PCT:-0.05}"
    local tp_buf="${TP_OB_BUFFER_PCT:-0.05}"
    local min_gap="${OB_GRID_MIN_R0_R1_GAP_PCT:-0.2}"
    local range_ratio="${OB_GRID_SL_RANGE_RATIO:-0.382}"
    local gap_pct sl_top sl_range r1_for_sl s1_for_sl

    direction=$(echo "$direction" | tr '[:lower:]' '[:upper:]')
    r0=$(ob_get SIGNAL_R0 "$symbol")
    r1=$(ob_get SIGNAL_R1 "$symbol")
    r2=$(ob_get SIGNAL_R2 "$symbol")
    s0=$(ob_get SIGNAL_S0 "$symbol")
    s1=$(ob_get SIGNAL_S1 "$symbol")
    s2=$(ob_get SIGNAL_S2 "$symbol")

    if [ "$direction" = "LONG" ]; then
        s1_for_sl="$s1"
        gap_pct=$(_ob_wh_wall_gap_pct "$s0" "$s1")
        if [ -n "$gap_pct" ] && awk -v g="$gap_pct" -v m="$min_gap" 'BEGIN { exit (g + 0 < m + 0) ? 0 : 1 }' \
            && _ob_wh_is_positive "$s2"; then
            s1_for_sl=$(_ob_wh_min_price "$s1" "$s2")
            note="ob_grid S1~S0 gap=${gap_pct}% using min(S1,S2)"
        fi
        if _ob_wh_is_positive "$s1_for_sl"; then
            sl=$(echo "$s1_for_sl * (1 - $sl_buf/100)" | bc -l 2>/dev/null)
            note="${note} SL=S1($s1_for_sl)"
        fi
        if _ob_wh_is_positive "$r0"; then
            tp=$(echo "$r0 * (1 + $tp_buf/100)" | bc -l 2>/dev/null)
            note="${note} TP=R0($r0)"
        fi
        if _ob_wh_is_positive "$s0" && _ob_wh_is_positive "$r0" && _ob_wh_bc_gt "$r0" "$s0"; then
            sl_range=$(echo "$s0 - ($r0 - $s0) * $range_ratio" | bc -l 2>/dev/null)
            if _ob_wh_is_positive "$sl_range" && { ! _ob_wh_is_positive "$sl" || _ob_wh_bc_gt "$sl" "$sl_range"; }; then
                sl=$(echo "$sl_range * (1 - $sl_buf/100)" | bc -l 2>/dev/null)
                note="${note} SL=range_below_S0"
            fi
        fi
        if _ob_wh_is_positive "$entry" && _ob_wh_is_positive "$sl" \
            && _ob_wh_bc_gt "$sl" "$entry"; then
            if _ob_wh_is_positive "$s0"; then
                sl=$(echo "$s0 * (1 - $sl_buf/100)" | bc -l 2>/dev/null)
                note="${note} SL=S0($s0) S1 above entry"
            fi
        fi
        if ! _ob_wh_is_positive "$sl" && _ob_wh_is_positive "$s0"; then
            sl=$(echo "$s0 * (1 - $sl_buf/100)" | bc -l 2>/dev/null)
            note="${note} SL=S0($s0) no S1"
        fi
        if _ob_wh_is_positive "$sl"; then
            sl=$(_ob_wh_enforce_min_sl_distance "$entry" "$sl" "LONG")
        fi
    elif [ "$direction" = "SHORT" ]; then
        # SHORT stop must sit above entry: use R1 only if meaningfully separated from R0, else R2 / range / min %
        r1_for_sl="$r1"
        gap_pct=$(_ob_wh_wall_gap_pct "$r0" "$r1")
        if [ -z "$gap_pct" ] || awk -v g="$gap_pct" -v m="$min_gap" 'BEGIN { exit (g + 0 < m + 0) ? 0 : 1 }'; then
            if _ob_wh_is_positive "$r2"; then
                r1_for_sl=$(_ob_wh_max_price "$r1" "$r2")
                note="ob_grid R0~R1 gap=${gap_pct:-0}% using max(R1,R2)"
            else
                note="ob_grid R0~R1 tight gap=${gap_pct:-0}%"
            fi
        fi
        sl_top=$(_ob_wh_max_price "$r0" "$r1_for_sl")
        if _ob_wh_is_positive "$sl_top"; then
            sl=$(echo "$sl_top * (1 + $sl_buf/100)" | bc -l 2>/dev/null)
            note="${note} SL=top($sl_top) R0=$r0 R1=$r1"
        fi
        if _ob_wh_is_positive "$s0"; then
            tp=$(echo "$s0 * (1 - $tp_buf/100)" | bc -l 2>/dev/null)
            note="${note} TP=S0($s0)"
        fi
        if _ob_wh_is_positive "$s0" && _ob_wh_is_positive "$r0" && _ob_wh_bc_gt "$r0" "$s0"; then
            sl_range=$(echo "$r0 + ($r0 - $s0) * $range_ratio" | bc -l 2>/dev/null)
            if _ob_wh_is_positive "$sl_range" && { ! _ob_wh_is_positive "$sl" || _ob_wh_bc_lt "$sl" "$sl_range"; }; then
                sl=$(echo "$sl_range * (1 + $sl_buf/100)" | bc -l 2>/dev/null)
                note="${note} SL=range_above_R0"
            fi
        fi
        if _ob_wh_is_positive "$entry" && _ob_wh_is_positive "$sl" \
            && _ob_wh_bc_lt "$sl" "$entry"; then
            if _ob_wh_is_positive "$r0"; then
                sl=$(echo "$r0 * (1 + $sl_buf/100)" | bc -l 2>/dev/null)
                note="${note} SL=R0($r0) below entry"
            fi
        fi
        if ! _ob_wh_is_positive "$sl" && _ob_wh_is_positive "$r0"; then
            sl=$(echo "$r0 * (1 + $sl_buf/100)" | bc -l 2>/dev/null)
            note="${note} SL=R0($r0) no R1"
        fi
        if _ob_wh_is_positive "$sl"; then
            local sl_before="$sl"
            sl=$(_ob_wh_enforce_min_sl_distance "$entry" "$sl" "SHORT")
            if [ "$sl" != "$sl_before" ]; then
                note="${note} widened_min_sl_pct"
            fi
        fi
    fi

    if _ob_wh_is_positive "$sl" && _ob_wh_is_positive "$tp" && _ob_wh_is_positive "$entry"; then
        if [ "$direction" = "LONG" ]; then
            if _ob_wh_bc_lt "$tp" "$entry" || _ob_wh_bc_gt "$sl" "$entry"; then
                sl=""
                tp=""
                note="ob_grid invalid LONG geometry"
            fi
        elif [ "$direction" = "SHORT" ]; then
            if _ob_wh_bc_gt "$tp" "$entry" || _ob_wh_bc_lt "$sl" "$entry"; then
                sl=""
                tp=""
                note="ob_grid invalid SHORT geometry"
            fi
        fi
    fi

    if declare -f round_price_for_symbol >/dev/null 2>&1; then
        [ -n "$sl" ] && _ob_wh_is_positive "$sl" && sl=$(round_price_for_symbol "$symbol" "$sl")
        [ -n "$tp" ] && _ob_wh_is_positive "$tp" && tp=$(round_price_for_symbol "$symbol" "$tp")
    fi

    echo "${sl:-0}|${tp:-0}|${note:-ob_grid}"
}
