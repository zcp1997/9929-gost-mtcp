#!/usr/bin/env bash
set -uo pipefail

CONFIG_DEFAULT="/root/9929-gost-mtcp/cn/mtcp.conf"

load_config() {
    local cfg="${1:-$CONFIG_DEFAULT}"
    [[ -r "$cfg" ]] || { echo "config not readable: $cfg" >&2; return 1; }
    # shellcheck disable=SC1090
    source "$cfg"

    : "${UNIT:?UNIT missing}"
    : "${ANCHOR_UNIT:?ANCHOR_UNIT missing}"
    : "${DST:?DST missing}"
    : "${PORT:?PORT missing}"
    : "${BUSINESS_PORT:?BUSINESS_PORT missing}"
    : "${ANCHOR_HOST:?ANCHOR_HOST missing}"
    : "${ANCHOR_PORT:?ANCHOR_PORT missing}"
    : "${ACCEPT_RTT_MS:?ACCEPT_RTT_MS missing}"

    STATE_DIR="${STATE_DIR:-/root/9929-gost-mtcp/cn/state}"
    STATE_FILE="${STATE_FILE:-${STATE_DIR}/runtime.state}"
    STATUS_JSON="${STATUS_JSON:-${STATE_DIR}/status.json}"
    EVENT_FILE="${EVENT_FILE:-${STATE_DIR}/events.jsonl}"
    RETENTION_SEC="${RETENTION_SEC:-86400}"
    mkdir -p "$STATE_DIR"
}

now_epoch() { date +%s; }
now_text() { date '+%F %T'; }

json_escape() {
    local s="${1:-}"
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

prune_events() {
    local now cutoff tmp
    now="$(now_epoch)"; cutoff=$((now - RETENTION_SEC))
    [[ -f "$EVENT_FILE" ]] || return 0
    tmp="${EVENT_FILE}.tmp.$$"
    awk -v cutoff="$cutoff" '
      { if (match($0, /"epoch":[0-9]+/)) { e=substr($0,RSTART+8,RLENGTH-8)+0; if (e>=cutoff) print $0 } }
    ' "$EVENT_FILE" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$EVENT_FILE"
}

log_event() {
    local state="${1:-UNKNOWN}" event="${2:-EVENT}" reason="${3:-}"
    local pid="${4:-0}" sport="${5:-}" minrtt="${6:-}" rtt="${7:-}" extra="${8:-}"
    local epoch ts
    epoch="$(now_epoch)"; ts="$(now_text)"
    printf '{"epoch":%s,"ts":"%s","state":"%s","event":"%s","reason":"%s","pid":%s,"sport":"%s","minrtt_ms":"%s","rtt_ms":"%s","extra":"%s"}\n' \
      "$epoch" "$(json_escape "$ts")" "$(json_escape "$state")" "$(json_escape "$event")" "$(json_escape "$reason")" \
      "${pid:-0}" "$(json_escape "$sport")" "$(json_escape "$minrtt")" "$(json_escape "$rtt")" "$(json_escape "$extra")" >> "$EVENT_FILE"
}

get_unit_main_pid() {
    local unit="$1" pid
    pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) echo 0 ;; *) echo "$pid" ;; esac
}
get_main_pid() { get_unit_main_pid "$UNIT"; }
get_anchor_pid() { get_unit_main_pid "$ANCHOR_UNIT"; }
service_is_active() { systemctl is-active --quiet "$UNIT"; }
anchor_is_active() { systemctl is-active --quiet "$ANCHOR_UNIT"; }

get_gost_outer_sports() {
    local pid="$1"
    (( pid > 0 )) || return 0
    ss -ntpH "dst ${DST}:${PORT}" 2>/dev/null |
      awk -v needle="pid=${pid}," '$1=="ESTAB" && index($0,needle) { ep=$4; sub(/^.*:/,"",ep); print ep }'
}
get_gost_outer_count() { get_gost_outer_sports "$1" | awk 'END {print NR+0}'; }
get_single_sport() {
    local -a sports=()
    mapfile -t sports < <(get_gost_outer_sports "$1")
    (( ${#sports[@]} == 1 )) || return 1
    printf '%s\n' "${sports[0]}"
}

get_tcp_info() {
    local sport="$1" raw minrtt="" rtt=""
    raw="$(ss -tinH "dst ${DST}:${PORT} sport = :${sport}" 2>/dev/null | tr '\n' ' ')"
    [[ "$raw" =~ minrtt:([0-9.]+) ]] && minrtt="${BASH_REMATCH[1]}"
    [[ "$raw" =~ rtt:([0-9.]+)/[0-9.]+ ]] && rtt="${BASH_REMATCH[1]}"
    printf '%s|%s\n' "$minrtt" "$rtt"
}

is_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }
is_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

get_business_conn_count() {
    local pid="$1"
    (( pid > 0 )) || { echo 0; return; }
    ss -ntpH "sport = :${BUSINESS_PORT}" 2>/dev/null |
      awk -v needle="pid=${pid}," '$1=="ESTAB" && index($0,needle){n++} END{print n+0}'
}

get_anchor_conn_count() {
    local apid="$1"
    (( apid > 0 )) || { echo 0; return; }
    ss -ntpH "dst ${ANCHOR_HOST}:${ANCHOR_PORT}" 2>/dev/null |
      awk -v needle="pid=${apid}," '$1=="ESTAB" && index($0,needle){n++} END{print n+0}'
}

anchor_is_established() {
    local apid count
    apid="$(get_anchor_pid)"; (( apid > 0 )) || return 1
    count="$(get_anchor_conn_count "$apid")"
    [[ "$count" == "1" ]]
}

stop_anchor() {
    systemctl stop "$ANCHOR_UNIT" >/dev/null 2>&1 || true
}

start_anchor() {
    systemctl reset-failed "$ANCHOR_UNIT" >/dev/null 2>&1 || true
    systemctl start "$ANCHOR_UNIT" >/dev/null 2>&1
}

ensure_anchor() {
    local deadline stable=0 apid count
    start_anchor || return 1
    deadline=$((SECONDS + ${ANCHOR_START_TIMEOUT_SEC:-8}))
    while (( SECONDS < deadline )); do
        apid="$(get_anchor_pid)"
        count="$(get_anchor_conn_count "$apid")"
        if (( apid > 0 && count == 1 )); then
            ((stable++))
            if (( stable >= ${ANCHOR_STABLE_REQUIRED:-2} )); then return 0; fi
        else
            stable=0
        fi
        sleep "${ANCHOR_STABLE_INTERVAL_SEC:-1}"
    done
    return 1
}

remote_tcp_reachable() {
    local i attempts="${REMOTE_PROBE_ATTEMPTS:-2}"
    for ((i=1;i<=attempts;i++)); do
        if timeout "${REMOTE_PROBE_TIMEOUT_SEC:-2}" bash -c "exec 3<>/dev/tcp/${DST}/${PORT}" >/dev/null 2>&1; then return 0; fi
        sleep 0.2
    done
    return 1
}

kill_outer_sport() {
    local pid="$1" sport="$2" current count
    count="$(get_gost_outer_count "$pid")"; [[ "$count" == "1" ]] || return 1
    current="$(get_single_sport "$pid" 2>/dev/null || true)"; [[ "$current" == "$sport" ]] || return 1
    ss -K "dst ${DST}:${PORT} sport = :${sport}" >/dev/null 2>&1
}

wait_outer_gone() {
    local pid="$1" old_sport="$2" timeout_sec="$3" deadline current
    deadline=$((SECONDS + timeout_sec))
    while (( SECONDS < deadline )); do
        current="$(get_single_sport "$pid" 2>/dev/null || true)"
        [[ -z "$current" || "$current" != "$old_sport" ]] && return 0
        sleep 0.1
    done
    return 1
}

write_status_json() {
    local state="${1:-UNKNOWN}" reason="${2:-}" pid="${3:-0}" sport="${4:-}"
    local minrtt="${5:-}" rtt="${6:-}" outer="${7:-0}" remote="${8:-unknown}"
    local apid acount business astate tmp epoch ts
    apid="$(get_anchor_pid)"; acount="$(get_anchor_conn_count "$apid")"
    business="$(get_business_conn_count "$pid")"
    if (( apid > 0 && acount == 1 )); then astate="up"; elif (( apid > 0 )); then astate="starting"; else astate="down"; fi
    epoch="$(now_epoch)"; ts="$(now_text)"; tmp="${STATUS_JSON}.tmp.$$"
    printf '{"epoch":%s,"ts":"%s","state":"%s","reason":"%s","unit":"%s","dst":"%s","port":%s,"pid":%s,"outer_count":%s,"sport":"%s","minrtt_ms":"%s","rtt_ms":"%s","remote_reachable":"%s","anchor_unit":"%s","anchor_state":"%s","anchor_pid":%s,"anchor_connections":%s,"business_connections":%s}\n' \
      "$epoch" "$(json_escape "$ts")" "$(json_escape "$state")" "$(json_escape "$reason")" "$(json_escape "$UNIT")" \
      "$(json_escape "$DST")" "$PORT" "${pid:-0}" "${outer:-0}" "$(json_escape "$sport")" "$(json_escape "$minrtt")" "$(json_escape "$rtt")" \
      "$(json_escape "$remote")" "$(json_escape "$ANCHOR_UNIT")" "$astate" "${apid:-0}" "${acount:-0}" "${business:-0}" > "$tmp"
    mv -f "$tmp" "$STATUS_JSON"
}
