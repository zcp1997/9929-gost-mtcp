#!/usr/bin/env bash
set -uo pipefail

CONFIG="${1:-/root/9929-gost-mtcp/cn/mtcp.conf}"
LIB="${MTCP_LIB:-/root/9929-gost-mtcp/cn/mtcp-lib.sh}"
PREWARM="${MTCP_PREWARM:-/root/9929-gost-mtcp/cn/mtcp-prewarm.sh}"
# shellcheck disable=SC1090
source "$LIB"
load_config "$CONFIG" || exit 1

LOCK="/run/9929-gost-mtcp-watchdog.lock"
exec {LOCKFD}>"$LOCK"
flock -n "$LOCKFD" || exit 0

BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
STATE="INIT"; REASON=""; LAST_PID=0; LAST_NONZERO_PID=0; LAST_SPORT=""
ZERO_SINCE=0; WARN_SINCE=0; CRIT_SINCE=0; RECOVER_SINCE=0
LAST_REMOTE_PROBE=0; REMOTE_OK="unknown"; LAST_RESTART=0; MULTI_SEEN=0
LAST_DEGRADED_RETRY=0; LAST_RECOVERY_ATTEMPT=0; LAST_ANCHOR_RETRY=0; LAST_PRUNE=0
HAVE_RUNTIME=0

load_runtime_state() {
    [[ -r "$STATE_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$STATE_FILE" || return 1
    [[ "${SAVED_BOOT_ID:-}" == "$BOOT_ID" ]] || return 1
    HAVE_RUNTIME=1
    return 0
}

save_runtime_state() {
    local tmp="${STATE_FILE}.tmp.$$"; umask 077
    cat > "$tmp" <<STATEEOF
SAVED_BOOT_ID='$BOOT_ID'
STATE='$STATE'
REASON='$REASON'
LAST_PID='$LAST_PID'
LAST_NONZERO_PID='$LAST_NONZERO_PID'
LAST_SPORT='$LAST_SPORT'
ZERO_SINCE='$ZERO_SINCE'
WARN_SINCE='$WARN_SINCE'
CRIT_SINCE='$CRIT_SINCE'
RECOVER_SINCE='$RECOVER_SINCE'
LAST_REMOTE_PROBE='$LAST_REMOTE_PROBE'
REMOTE_OK='$REMOTE_OK'
LAST_RESTART='$LAST_RESTART'
MULTI_SEEN='$MULTI_SEEN'
LAST_DEGRADED_RETRY='$LAST_DEGRADED_RETRY'
LAST_RECOVERY_ATTEMPT='$LAST_RECOVERY_ATTEMPT'
LAST_ANCHOR_RETRY='$LAST_ANCHOR_RETRY'
LAST_PRUNE='$LAST_PRUNE'
STATEEOF
    mv -f "$tmp" "$STATE_FILE"
}

set_state() {
    local new_state="$1" new_reason="$2" pid="${3:-0}" sport="${4:-}" minrtt="${5:-}" rtt="${6:-}" outer="${7:-0}"
    if [[ "$STATE" != "$new_state" || "$REASON" != "$new_reason" ]]; then
        STATE="$new_state"; REASON="$new_reason"
        log_event "$STATE" "STATE_CHANGE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt"
    else
        STATE="$new_state"; REASON="$new_reason"
    fi
    write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" "$outer" "$REMOTE_OK"
}

restart_gost_rate_limited() {
    local reason="$1" now
    now="$(now_epoch)"
    if (( LAST_RESTART > 0 && now - LAST_RESTART < ${RESTART_COOLDOWN_SEC:-300} )); then
        log_event "FAULT" "RESTART_SKIPPED_COOLDOWN" "$reason" "$LAST_PID" "$LAST_SPORT"
        return 1
    fi
    LAST_RESTART="$now"
    stop_anchor
    log_event "FAULT" "RESTART_GOST" "$reason" "$LAST_PID" "$LAST_SPORT"
    systemctl restart "$UNIT" || true
    (( LAST_PID > 0 )) && LAST_NONZERO_PID="$LAST_PID"
    LAST_PID=0; LAST_SPORT=""; ZERO_SINCE=0; MULTI_SEEN=0
    return 0
}

# v1 的 prewarm 已经负责：建立候选 Anchor -> 测 minrtt -> 慢路重抽 -> 成功后直接留下 Anchor。
run_select() {
    local mode="${1:-normal}" cause="${2:-SELECT}" rc pid count sport info minrtt rtt
    MTCP_PREWARM_MODE="$mode" "$PREWARM" "$CONFIG"; rc=$?

    case "$rc" in
      0|10)
        pid="$(get_main_pid)"; count="$(get_gost_outer_count "$pid")"
        if (( pid <= 0 || count != 1 )) || ! anchor_is_established; then
            STATE="FAULT"; REASON="SELECT_VERIFY_FAILED"
            log_event "FAULT" "SELECT_VERIFY_FAILED" "$REASON" "$pid" "" "" "" "rc=$rc count=$count cause=$cause"
            return 32
        fi
        sport="$(get_single_sport "$pid" 2>/dev/null || true)"
        info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
        LAST_PID="$pid"; LAST_NONZERO_PID="$pid"; LAST_SPORT="$sport"; ZERO_SINCE=0; REMOTE_OK="yes"; LAST_ANCHOR_RETRY=0
        if (( rc == 0 )); then
            STATE="FAST"; REASON="PATH"; LAST_DEGRADED_RETRY=0
            log_event "FAST" "ANCHOR_BOUND" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "cause=$cause"
        else
            STATE="DEGRADED"; REASON="PATH"; LAST_DEGRADED_RETRY="$(now_epoch)"
            log_event "DEGRADED" "ANCHOR_BOUND_SLOW" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "cause=$cause"
        fi
        write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" 1 "$REMOTE_OK"
        return "$rc"
        ;;
      11)
        pid="$(get_main_pid)"; count="$(get_gost_outer_count "$pid")"
        sport="$(get_single_sport "$pid" 2>/dev/null || true)"
        info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
        STATE="DEGRADED"; REASON="ANCHOR"; LAST_PID="$pid"; LAST_SPORT="$sport"; LAST_ANCHOR_RETRY="$(now_epoch)"
        write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" "$count" "$REMOTE_OK"
        return 11
        ;;
      20)
        STATE="DOWN"; REASON="NO_OUTER"
        return 20
        ;;
      75) return 75 ;;
      *)
        STATE="FAULT"; REASON="PREWARM_RC_${rc}"
        log_event "FAULT" "SELECT_PREWARM_FAILED" "$REASON" "$(get_main_pid)" "" "" "" "cause=$cause"
        restart_gost_rate_limited "$REASON" || true
        return "$rc"
        ;;
    esac
}

adopt_current() {
    local pid count sport info minrtt rtt
    pid="$(get_main_pid)"; count="$(get_gost_outer_count "$pid")"
    if (( pid <= 0 || count != 1 )); then echo "cannot adopt: pid=$pid outer_count=$count" >&2; return 1; fi
    if ! anchor_is_established; then echo "cannot adopt: anchor is not established" >&2; return 1; fi
    sport="$(get_single_sport "$pid")"; info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
    [[ -n "$minrtt" ]] || { echo "cannot adopt: minrtt unavailable" >&2; return 1; }
    if ! is_lt "$minrtt" "$ACCEPT_RTT_MS"; then
        log_event "DEGRADED" "ADOPT_REFUSED_SLOW" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "accept<$ACCEPT_RTT_MS"
        echo "cannot adopt: minrtt=${minrtt}ms is not FAST (<${ACCEPT_RTT_MS}ms)" >&2
        return 2
    fi
    LAST_PID="$pid"; LAST_NONZERO_PID="$pid"; LAST_SPORT="$sport"; ZERO_SINCE=0; REMOTE_OK="yes"; STATE="FAST"; REASON="PATH"
    log_event "FAST" "ADOPT_EXISTING_FAST" "PATH" "$pid" "$sport" "$minrtt" "$rtt"
    write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" 1 "$REMOTE_OK"
    save_runtime_state
}

if [[ "${2:-}" == "--adopt" || "${1:-}" == "--adopt" ]]; then
    [[ "${1:-}" == "--adopt" ]] && CONFIG="/root/9929-gost-mtcp/cn/mtcp.conf"
    load_config "$CONFIG" || exit 1
    adopt_current
    exit $?
fi

load_runtime_state || true

while true; do
    load_config "$CONFIG" || { sleep 5; continue; }
    now="$(now_epoch)"
    if (( now - LAST_PRUNE >= 3600 )); then prune_events; LAST_PRUNE="$now"; fi

    pid="$(get_main_pid)"
    if (( pid <= 0 )) || ! service_is_active; then
        stop_anchor
        (( LAST_PID > 0 )) && LAST_NONZERO_PID="$LAST_PID"
        LAST_PID=0; LAST_SPORT=""; ZERO_SINCE=0
        set_state "DOWN" "PROCESS" "$pid" "" "" "" 0
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    # 无可用 runtime（首次部署/重启 watchdog 且状态被清理/跨 reboot）：明确记录 COLD_START，不冒充 GOST 重启。
    if (( HAVE_RUNTIME == 0 )); then
        log_event "DOWN" "WATCHDOG_COLD_START" "INIT" "$pid"
        LAST_PID="$pid"; LAST_NONZERO_PID="$pid"; LAST_SPORT=""; ZERO_SINCE=0; MULTI_SEEN=0; REMOTE_OK="unknown"
        if remote_tcp_reachable; then
            REMOTE_OK="yes"; run_select normal "COLD_START" || true
        else
            REMOTE_OK="no"; set_state "DOWN" "REMOTE" "$pid" "" "" "" 0
        fi
        HAVE_RUNTIME=1
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    # 真正的 GOST PID 换代。
    if [[ "$LAST_PID" != "$pid" ]]; then
        old_pid="$LAST_NONZERO_PID"
        (( old_pid > 0 )) || old_pid="$LAST_PID"
        stop_anchor
        LAST_PID="$pid"; LAST_NONZERO_PID="$pid"; LAST_SPORT=""; ZERO_SINCE=0; MULTI_SEEN=0
        log_event "DOWN" "GOST_PID_CHANGED" "PROCESS" "$pid" "" "" "" "old_pid=$old_pid"
        if remote_tcp_reachable; then
            REMOTE_OK="yes"; run_select normal "GOST_PID_CHANGED" || true
        else
            REMOTE_OK="no"; set_state "DOWN" "REMOTE" "$pid" "" "" "" 0
        fi
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    count="$(get_gost_outer_count "$pid")"

    if (( count > 1 )); then
        ((MULTI_SEEN++)); set_state "FAULT" "MULTI_OUTER" "$pid" "" "" "" "$count"
        if (( MULTI_SEEN >= ${MULTI_CONFIRM_COUNT:-2} )); then restart_gost_rate_limited "MULTI_OUTER" || true; fi
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    else
        MULTI_SEEN=0
    fi

    if (( count == 0 )); then
        WARN_SINCE=0; CRIT_SINCE=0; RECOVER_SINCE=0; LAST_SPORT=""
        stop_anchor
        if (( ZERO_SINCE == 0 )); then
            ZERO_SINCE="$now"
            log_event "DOWN" "OUTER_DISAPPEARED" "NO_OUTER" "$pid"
        fi

        if (( now - ZERO_SINCE < ${ZERO_GRACE_SEC:-5} )); then
            if [[ "$REMOTE_OK" == "no" ]]; then
                set_state "DOWN" "REMOTE" "$pid" "" "" "" 0
            else
                set_state "DOWN" "NO_OUTER" "$pid" "" "" "" 0
            fi
            save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
        fi

        if (( now - LAST_REMOTE_PROBE >= ${REMOTE_PROBE_INTERVAL_SEC:-15} )); then
            LAST_REMOTE_PROBE="$now"; old_remote="$REMOTE_OK"
            if remote_tcp_reachable; then
                REMOTE_OK="yes"
                [[ "$old_remote" == "yes" ]] || log_event "DOWN" "REMOTE_TCP_UP" "REMOTE" "$pid"
            else
                REMOTE_OK="no"
                [[ "$old_remote" == "no" ]] || log_event "DOWN" "REMOTE_TCP_DOWN" "REMOTE" "$pid"
            fi
        fi

        if [[ "$REMOTE_OK" == "no" ]]; then
            set_state "DOWN" "REMOTE" "$pid" "" "" "" 0
            save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
        fi

        if [[ "$REMOTE_OK" != "yes" ]]; then
            set_state "DOWN" "NO_OUTER" "$pid" "" "" "" 0
            save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
        fi

        if (( LAST_RECOVERY_ATTEMPT == 0 || now - LAST_RECOVERY_ATTEMPT >= ${DOWN_RETRY_SEC:-15} )); then
            LAST_RECOVERY_ATTEMPT="$now"
            log_event "DOWN" "RECOVERY_SELECT" "REMOTE_UP" "$pid"
            run_select recovery "REMOTE_RECOVERY" || true
        fi

        if (( ZERO_SINCE > 0 && now - ZERO_SINCE >= ${STUCK_RESTART_AFTER_SEC:-60} )) && [[ "$REMOTE_OK" == "yes" ]]; then
            restart_gost_rate_limited "REMOTE_UP_BUT_NO_OUTER" || true
        fi
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    # outer == 1
    ZERO_SINCE=0; LAST_RECOVERY_ATTEMPT=0; REMOTE_OK="yes"
    sport="$(get_single_sport "$pid" 2>/dev/null || true)"
    [[ -n "$sport" ]] || { save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue; }
    info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
    business="$(get_business_conn_count "$pid")"

    if [[ -z "$LAST_SPORT" ]]; then
        LAST_SPORT="$sport"
        run_select normal "INITIAL_NO_SPORT" || true
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    if [[ "$LAST_SPORT" != "$sport" ]]; then
        old_sport="$LAST_SPORT"
        log_event "DOWN" "SESSION_CHANGED" "NEW_SPORT" "$pid" "$sport" "$minrtt" "$rtt" "old=$old_sport business=$business"
        LAST_SPORT="$sport"
        run_select recovery "SESSION_CHANGED" || true
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    # Anchor 自己掉了：优先重新挂回当前 outer，不因辅助组件故障主动重抽。
    if ! anchor_is_established; then
        if (( LAST_ANCHOR_RETRY == 0 || now - LAST_ANCHOR_RETRY >= ${ANCHOR_RETRY_SEC:-60} )); then
            LAST_ANCHOR_RETRY="$now"; before_sport="$sport"
            if ensure_anchor; then
                after_count="$(get_gost_outer_count "$pid")"
                after_sport="$(get_single_sport "$pid" 2>/dev/null || true)"
                if (( after_count == 1 )) && [[ "$after_sport" == "$before_sport" ]]; then
                    LAST_ANCHOR_RETRY=0
                    log_event "$STATE" "ANCHOR_RESTORED" "ANCHOR" "$pid" "$sport" "$minrtt" "$rtt"
                else
                    stop_anchor
                    log_event "DOWN" "ANCHOR_RESTORE_SESSION_CHANGED" "NEW_SPORT" "$pid" "$after_sport" "" "" "old=$before_sport count=$after_count"
                    run_select recovery "ANCHOR_CHANGED_SESSION" || true
                    save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
                fi
            else
                stop_anchor
                set_state "DEGRADED" "ANCHOR" "$pid" "$sport" "$minrtt" "$rtt" 1
                save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
            fi
        else
            set_state "DEGRADED" "ANCHOR" "$pid" "$sport" "$minrtt" "$rtt" 1
            save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
        fi
    fi

    LAST_SPORT="$sport"; LAST_PID="$pid"; LAST_NONZERO_PID="$pid"

    base_state="FAST"; base_reason="PATH"
    if [[ -n "$minrtt" ]] && ! is_lt "$minrtt" "$ACCEPT_RTT_MS"; then base_state="DEGRADED"; base_reason="PATH"; fi

    if [[ "$base_state" == "DEGRADED" ]]; then
        if (( LAST_DEGRADED_RETRY == 0 )); then LAST_DEGRADED_RETRY="$now"; fi
        if (( now - LAST_DEGRADED_RETRY >= ${DEGRADED_RETRY_SEC:-900} )); then
            if (( business == 0 )); then
                LAST_DEGRADED_RETRY="$now"
                log_event "DEGRADED" "DEGRADED_RETRY_IDLE" "PATH" "$pid" "$sport" "$minrtt" "$rtt"
                run_select degraded-retry "DEGRADED_IDLE_RETRY" || true
                save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
            else
                LAST_DEGRADED_RETRY=$((now - ${DEGRADED_RETRY_SEC:-900} + ${DEGRADED_BUSY_DEFER_SEC:-60}))
                log_event "DEGRADED" "DEGRADED_RETRY_DEFER_BUSY" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "business=$business"
            fi
        fi
    else
        LAST_DEGRADED_RETRY=0
    fi

    # LIVE RTT 只做状态化，不主动 kill 当前 outer。
    if [[ "$REASON" == "LIVE_RTT_WARN" || "$REASON" == "LIVE_RTT_CRIT" ]]; then
        if [[ -n "$rtt" ]] && is_lt "$rtt" "${LIVE_RTT_RECOVER_MS:-80}"; then
            if (( RECOVER_SINCE == 0 )); then RECOVER_SINCE="$now"; fi
            if (( now - RECOVER_SINCE >= ${LIVE_RTT_RECOVER_HOLD_SEC:-30} )); then
                WARN_SINCE=0; CRIT_SINCE=0; RECOVER_SINCE=0
                set_state "$base_state" "$base_reason" "$pid" "$sport" "$minrtt" "$rtt" 1
            else
                set_state "DEGRADED" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" 1
            fi
        else
            RECOVER_SINCE=0
            if [[ -n "$rtt" ]] && is_ge "$rtt" "${LIVE_RTT_CRIT_MS:-250}"; then REASON="LIVE_RTT_CRIT"; fi
            set_state "DEGRADED" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" 1
        fi
    elif [[ -n "$rtt" ]] && is_ge "$rtt" "${LIVE_RTT_CRIT_MS:-250}"; then
        WARN_SINCE=0; RECOVER_SINCE=0; (( CRIT_SINCE == 0 )) && CRIT_SINCE="$now"
        if (( now - CRIT_SINCE >= ${LIVE_RTT_CRIT_HOLD_SEC:-120} )); then set_state "DEGRADED" "LIVE_RTT_CRIT" "$pid" "$sport" "$minrtt" "$rtt" 1
        else set_state "$base_state" "RTT_TRANSIENT" "$pid" "$sport" "$minrtt" "$rtt" 1; fi
    elif [[ -n "$rtt" ]] && is_ge "$rtt" "${LIVE_RTT_WARN_MS:-120}"; then
        CRIT_SINCE=0; RECOVER_SINCE=0; (( WARN_SINCE == 0 )) && WARN_SINCE="$now"
        if (( now - WARN_SINCE >= ${LIVE_RTT_WARN_HOLD_SEC:-30} )); then set_state "DEGRADED" "LIVE_RTT_WARN" "$pid" "$sport" "$minrtt" "$rtt" 1
        else set_state "$base_state" "RTT_TRANSIENT" "$pid" "$sport" "$minrtt" "$rtt" 1; fi
    else
        WARN_SINCE=0; CRIT_SINCE=0; RECOVER_SINCE=0
        set_state "$base_state" "$base_reason" "$pid" "$sport" "$minrtt" "$rtt" 1
    fi

    save_runtime_state
    sleep "${WATCH_INTERVAL_SEC:-5}"
done
