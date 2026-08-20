#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
file_mode() {
    if stat -c '%a' "$1" 2>/dev/null; then
        return
    fi
    stat -f '%Lp' "$1"
}

bash -n install.sh standalone-install.sh scripts/generate-standalone.sh cn/compile-config.sh \
    ecmp-test.sh cn/mtcp-lib.sh cn/mtcp-prewarm.sh cn/mtcp-watchdog.sh
pass "all shell files parse"

(
    ecmp_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/ecmp-test.XXXXXX")"
    trap 'rm -rf "$ecmp_test_dir"' EXIT
    cat > "$ecmp_test_dir/ss" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SS_CALL_LOG"
case "$*" in
  "-Hntie state established")
    cat <<'SS'
0 0 192.0.2.10:40000 103.201.131.7:22 uid:0 ino:111 sk:1
 cubic rtt:99/1 minrtt:99
0 0 192.0.2.10:41000 103.201.131.7:22 uid:0 ino:222 sk:2
 bbr rtt:33.5/1 minrtt:33.319
ESTAB 0 0 192.0.2.10:42000 103.201.131.7:22 uid:0 ino:333 sk:3
 bbr rtt:34/1 minrtt:34
SS
    ;;
  *"src 192.0.2.10 sport = :41000 dst 103.201.131.7 dport = :22"*)
    cat <<'SS'
ESTAB 0 0 192.0.2.10:41000 103.201.131.7:22 ino:222
 bbr rtt:33.5/1 minrtt:33.319
SS
    ;;
  *) exit 1 ;;
esac
MOCK
    chmod +x "$ecmp_test_dir/ss"
    export SS_CALL_LOG="$ecmp_test_dir/ss-calls.log"
    SS_BIN="$ecmp_test_dir/ss"
    # shellcheck disable=SC1091
    source ecmp-test.sh

    [[ "$(socket_inode_from_link 'socket:[222]')" == 222 ]] || fail "socket inode parsing failed"
    if socket_inode_from_link 'pipe:[222]' >/dev/null; then fail "non-socket FD was accepted"; fi
    endpoints="$(get_socket_endpoints 222)"
    [[ "$endpoints" == "192.0.2.10:41000 103.201.131.7:22" ]] || \
        fail "ECMP test misparsed state-filtered ss output: $endpoints"
    [[ "$(get_socket_endpoints 333)" == "192.0.2.10:42000 103.201.131.7:22" ]] || \
        fail "ECMP test misparsed regular ss output"
    [[ "$(get_minrtt_for_flow 192.0.2.10:41000 103.201.131.7:22)" == 33.319 ]] || \
        fail "ECMP test read minrtt from the wrong flow"
    grep -Fq 'src 192.0.2.10 sport = :41000 dst 103.201.131.7 dport = :22' "$SS_CALL_LOG" || \
        fail "ECMP test did not query the complete TCP four-tuple"
)
! grep -q 'grep -m1.*minrtt\|10\\\.[0-9]' ecmp-test.sh || fail "unsafe ECMP lookup remains"
pass "ECMP sampler binds TCP_INFO reads to the current FD and four-tuple"

scripts/generate-standalone.sh --check >/dev/null
pass "standalone embedded payload matches canonical files"

grep -Fqx '    auther: mtcp-auth' remote/remote.yaml || fail "Remote Relay authenticator is missing"
grep -Fqx '          file: /root/gost-ecmp-pathlock/cn/instances/default/mtcp.auth' cn/cn.yaml || \
    fail "CN Relay connector auth is missing"
grep -Fq 'bash "$PROJECT_ROOT/standalone-install.sh" cn' install.sh || \
    fail "traditional installer does not delegate to the shared CN implementation"
! grep -Eq '^[[:space:]]*password:' remote/remote.yaml cn/cn.yaml || fail "plaintext password embedded in YAML"
grep -Fqx 'ExecStart=/root/gost-ecmp-pathlock/cn/gost -D -C /root/gost-ecmp-pathlock/cn/runtime.yaml' \
    cn/gost-ecmp-pathlock.service || fail "canonical CN unit does not use the aggregate config"
pass "canonical installs use file-backed Relay auth and one aggregate GOST config"

compile_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/pathlock-compile.XXXXXX")"
cn/compile-config.sh "$compile_test_dir/runtime.yaml" cn/cn.yaml
[[ "$(grep -c '^services:$' "$compile_test_dir/runtime.yaml")" == 1 && \
   "$(grep -c '^chains:$' "$compile_test_dir/runtime.yaml")" == 1 ]] || \
    fail "route compiler did not emit one aggregate document"
if cn/compile-config.sh "$compile_test_dir/duplicate.yaml" cn/cn.yaml cn/cn.yaml >/dev/null 2>&1; then
    fail "route compiler accepted duplicate services, chains, and Remote endpoints"
fi
rm -rf "$compile_test_dir"
pass "route compiler rejects aggregate identity and endpoint conflicts"

help_output="$(bash standalone-install.sh --help)"
[[ "$help_output" == *"打开统一管理菜单"* && "$help_output" == *"CN_INSTANCE"* ]] || \
    fail "standalone help misses menu or automation compatibility"
pipe_help="$(bash -s -- --help < standalone-install.sh)"
[[ "$pipe_help" == *"打开统一管理菜单"* ]] || fail "piped standalone help failed"
pass "standalone supports the management menu plus file and piped execution"

(
    integration_dir="$(mktemp -d "${TMPDIR:-/tmp}/standalone-integration.XXXXXX")"
    trap 'rm -rf "$integration_dir"' EXIT
    mkdir -p "$integration_dir/bin" "$integration_dir/systemd" "$integration_dir/systemctl-state"
    cat > "$integration_dir/bin/systemctl-mock" <<MOCK
#!/usr/bin/env bash
set -u
state_dir='$integration_dir/systemctl-state'
command_name="\${1:-}"; shift || true
case "\$command_name" in
  is-active)
    [[ "\${1:-}" == --quiet ]] && shift
    [[ -f "\$state_dir/\${1:-missing}" ]]
    ;;
  restart)
    [[ "\${MOCK_FAIL_RESTART:-0}" == 1 ]] && exit 1
    for unit in "\$@"; do touch "\$state_dir/\$unit"; done
    ;;
  show) echo 0 ;;
  *) exit 0 ;;
esac
MOCK
    chmod +x "$integration_dir/bin/systemctl-mock"
    for mock_command in flock timeout socat; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$integration_dir/bin/$mock_command"
        chmod +x "$integration_dir/bin/$mock_command"
    done
    cat > "$integration_dir/bin/ss" <<'MOCK'
#!/usr/bin/env bash
if [[ -n "${MOCK_BUSY_PORT:-}" && "$*" == *"sport = :$MOCK_BUSY_PORT"* && "$*" == *established* ]]; then
    echo "0 0 127.0.0.1:$MOCK_BUSY_PORT 198.51.100.10:40000"
fi
exit 0
MOCK
    chmod +x "$integration_dir/bin/ss"
    PATH="$integration_dir/bin:$PATH"

    # 只加载 standalone 的函数区，避免执行 main 和后面的嵌入 payload。
    awk '$0 == "main \"$@\"" { exit } { print }' standalone-install.sh > "$integration_dir/core.sh"
    # shellcheck disable=SC1090
    source "$integration_dir/core.sh"
    trap 'rm -rf "$integration_dir"' EXIT
    EMBEDDED_SOURCE="$ROOT_DIR/standalone-install.sh"
    INSTALL_BASE="$integration_dir/install"
    export MTCP_AUTH_PASSWORD="PathLock-Integration#2026"
    valid_mtcp_auth_password "$MTCP_AUTH_PASSWORD" || fail "valid MTCP password was rejected"
    if valid_mtcp_auth_password "too-short"; then fail "short MTCP password was accepted"; fi
    if valid_mtcp_auth_password "contains whitespace"; then fail "MTCP password with spaces was accepted"; fi
    SYSTEMD_DIR="$integration_dir/systemd"
    SYSTEMCTL_BIN="$integration_dir/bin/systemctl-mock"
    download_gost() {
        mkdir -p "$2"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$2/gost"
        chmod +x "$2/gost"
    }
    prompt_read() {
        local output_var="$1"
        printf -v "$output_var" '%s' "${PROMPTS[$PROMPT_INDEX]}"
        PROMPT_INDEX=$((PROMPT_INDEX + 1))
    }

    mkdir -p "$INSTALL_BASE/cn"
    cat > "$INSTALL_BASE/cn/mtcp.conf" <<'LEGACY'
UNIT="gost-mtcp-jp.service"
BUSINESS_PORT="45100"
ANCHOR_PORT="45101"
LEGACY
    awk '
      # 模拟升级前没有 connector.auth 的旧版 YAML，验证安装器会补上鉴权且保留 Relay。
      skip_old_auth && /^          / { next }
      skip_old_auth { skip_old_auth=0 }
      /^        auth:[[:space:]]*$/ { skip_old_auth=1; next }
      /^- name:[[:space:]]*mtcp-anchor([A-Za-z0-9_-]*)?[[:space:]]*$/ && !inserted {
        print "# standalone-relay: relay-45104"
        print "- name: relay-45104"
        print "  addr: :45104"
        print "  handler:"
        print "    type: tcp"
        print "    chain: chain-mtcp-default"
        print "  listener:"
        print "    type: tcp"
        print "  forwarder:"
        print "    nodes:"
        print "    - name: backend-45104"
        print "      addr: 127.0.0.1:2347"
        print ""
        inserted=1
      }
      { print }
    ' cn/cn.yaml > "$INSTALL_BASE/cn/cn.yaml"
    PROMPTS=(jp 45.142.125.253 5201 45100 45101 40); PROMPT_INDEX=0
    install_cn >/dev/null
    grep -q 'name: relay-45104' "$INSTALL_BASE/cn/instances/jp/cn.yaml" || \
        fail "legacy Relay was not preserved during migration"
    grep -q '^BUSINESS_PORTS="45100 45104"$' "$INSTALL_BASE/cn/instances/jp/mtcp.conf" || \
        fail "legacy Relay was not included in BUSINESS_PORTS"
    unset CN_INSTANCE CN_YAML_PATH CN_MTCP_CONFIG_PATH
    resolve_cn_relay_context
    [[ "$CN_RELAY_YAML" == "$INSTALL_BASE/cn/instances/jp/cn.yaml" ]] || \
        fail "Relay resolver preferred legacy flat config after migration"
    PROMPTS=(us 198.51.100.20 6600 45102 45103 45); PROMPT_INDEX=0
    install_cn >/dev/null

    jp="$INSTALL_BASE/cn/instances/jp"
    us="$INSTALL_BASE/cn/instances/us"
    [[ -f "$jp/cn.yaml" && -f "$jp/mtcp.conf" && -f "$jp/mtcp.auth" && -d "$jp/state" ]] || \
        fail "jp instance or auth file missing"
    [[ -f "$us/cn.yaml" && -f "$us/mtcp.conf" && -f "$us/mtcp.auth" && -d "$us/state" ]] || \
        fail "us instance or auth file missing"
    [[ "$(file_mode "$jp/mtcp.auth")" == 600 ]] || fail "CN auth file permissions are not 0600"
    grep -Fqx "mtcp $MTCP_AUTH_PASSWORD" "$jp/mtcp.auth" || fail "CN auth credentials are incorrect"
    grep -Fqx "          file: '$jp/mtcp.auth'" "$jp/cn.yaml" || fail "CN connector auth path was not rendered"
    ! grep -Fq "$MTCP_AUTH_PASSWORD" "$jp/cn.yaml" || fail "CN password leaked into YAML"
    grep -q 'DST="45.142.125.253"' "$jp/mtcp.conf" || fail "jp config was overwritten"
    grep -q 'DST="198.51.100.20"' "$us/mtcp.conf" || fail "us config is incorrect"
    grep -Fqx 'UNIT="gost-mtcp.service"' "$jp/mtcp.conf" || fail "jp does not use shared GOST unit"
    grep -Fqx 'UNIT="gost-mtcp.service"' "$us/mtcp.conf" || fail "us does not use shared GOST unit"
    [[ -f "$SYSTEMD_DIR/gost-mtcp.service" ]] || fail "shared GOST unit missing"
    [[ ! -e "$SYSTEMD_DIR/gost-mtcp-jp.service" && ! -e "$SYSTEMD_DIR/gost-mtcp-us.service" ]] || \
        fail "per-route GOST main units still exist"
    grep -Fqx "ExecStart=$INSTALL_BASE/cn/gost -D -C $INSTALL_BASE/cn/runtime.yaml" \
        "$SYSTEMD_DIR/gost-mtcp.service" || fail "shared unit does not use aggregate YAML"
    grep -Fq -- '- name: chain-mtcp-jp' "$INSTALL_BASE/cn/runtime.yaml" || fail "aggregate misses jp chain"
    grep -Fq -- '- name: chain-mtcp-us' "$INSTALL_BASE/cn/runtime.yaml" || fail "aggregate misses us chain"
    grep -Fq -- '- name: tcp-entry-jp' "$INSTALL_BASE/cn/runtime.yaml" || fail "aggregate misses jp service"
    grep -Fq -- '- name: tcp-entry-us' "$INSTALL_BASE/cn/runtime.yaml" || fail "aggregate misses us service"
    grep -Fqx "ExecStart=$INSTALL_BASE/cn/mtcp-watchdog.sh $jp/mtcp.conf" \
        "$SYSTEMD_DIR/gost-mtcp-jp-watchdog.service" || fail "watchdog unit does not use isolated state config"

    config_listing="$(list_installed_configurations)"
    [[ "$config_listing" == *"线路 jp"* && "$config_listing" == *"线路 us"* && \
       "$config_listing" == *"端口路径"* && "$config_listing" == *"127.0.0.1:2345"* ]] || \
        fail "management menu did not list routes and port paths"
    PROMPTS=(2); PROMPT_INDEX=0
    selected_yaml=""; selected_config=""
    select_cn_route selected_yaml selected_config "测试线路选择" >/dev/null || fail "route selection failed"
    [[ "$selected_yaml" == "$us/cn.yaml" && "$selected_config" == "$us/mtcp.conf" ]] || \
        fail "route selector did not return the selected instance"
    unset CN_INSTANCE CN_YAML_PATH CN_MTCP_CONFIG_PATH
    PROMPTS=(2); PROMPT_INDEX=0
    relay_list_output="$(manage_cn_relays list)"
    [[ "$relay_list_output" == *"tcp-entry-us"* ]] || \
        fail "Relay manager still requires CN_INSTANCE for multiple routes"

    mkdir -p "$jp/state"
    printf '%s\n' '{"state":"FAST","reason":"healthy","route":"jp"}' > "$jp/state/status.json"
    printf '%s\n' '{"event":"PREWARM_SUCCESS","route":"jp"}' > "$jp/state/events.jsonl"
    PROMPTS=(1 1 b); PROMPT_INDEX=0
    log_output="$(view_cn_route_logs)"
    [[ "$log_output" == *'"event":"PREWARM_SUCCESS"'* && "$log_output" == *"events.jsonl"* ]] || \
        fail "JSONL log menu did not show the selected route log"
    PROMPTS=(2 q); PROMPT_INDEX=0
    main_menu_output="$(interactive_main_menu)"
    [[ "$main_menu_output" == *"全新安装 CN 端 / Remote 端"* && \
       "$main_menu_output" == *"线路 jp"* && "$main_menu_output" == *"已退出"* ]] || \
        fail "top-level management menu did not dispatch configuration listing"

    set +e
    ( PROMPTS=(duplicate 45.142.125.253 5201 45110 45111 40); PROMPT_INDEX=0; install_cn >/dev/null 2>&1 )
    duplicate_endpoint_rc=$?
    set -e
    (( duplicate_endpoint_rc != 0 )) || fail "duplicate Remote endpoint was accepted in shared GOST"
    set +e
    ( export MOCK_BUSY_PORT=45100; unset CN_FORCE_RESTART; require_cn_restart_window "$INSTALL_BASE/cn" gost-mtcp.service ) \
        >/dev/null 2>&1
    busy_guard_rc=$?
    set -e
    (( busy_guard_rc != 0 )) || fail "shared GOST restart guard ignored active business"
    ( export MOCK_BUSY_PORT=45100 CN_FORCE_RESTART=1; require_cn_restart_window "$INSTALL_BASE/cn" gost-mtcp.service ) \
        >/dev/null 2>&1 || fail "CN_FORCE_RESTART did not override active-business guard"
    ( export MOCK_BUSY_PORT=45100; unset CN_FORCE_RESTART; PATHLOCK_INTERACTIVE_MENU=1
      PROMPTS=(y); PROMPT_INDEX=0
      require_cn_restart_window "$INSTALL_BASE/cn" gost-mtcp.service ) >/dev/null 2>&1 || \
        fail "management menu could not explicitly confirm an active-business restart"

    CN_RELAY_YAML="$jp/cn.yaml"; CN_RELAY_CONFIG="$jp/mtcp.conf"; CN_RELAY_DIR="$jp"
    CN_ROUTE_ID="jp"; CN_RELAY_UNIT="gost-mtcp.service"
    CN_RELAY_WATCHDOG_UNIT="gost-mtcp-jp-watchdog.service"
    CN_RELAY_CHAIN_NAME="chain-mtcp-jp"; CN_RELAY_ANCHOR_SERVICE="mtcp-anchor-jp"
    CN_PRIMARY_PORT=45100; CN_ANCHOR_PORT=45101
    CN_ROOT="$INSTALL_BASE/cn"; CN_RUNTIME_YAML="$CN_ROOT/runtime.yaml"
    CN_COMPILE_SCRIPT="$CN_ROOT/compile-config.sh"
    relay_candidate="$(mktemp "$jp/.relay-test.XXXXXX")"
    awk '
      /^- name:[[:space:]]*mtcp-anchor-jp[[:space:]]*$/ && !inserted {
        print "# standalone-relay: relay-45106"
        print "- name: relay-45106"
        print "  addr: :45106"
        print "  handler:"
        print "    type: tcp"
        print "    chain: chain-mtcp-jp"
        print "  listener:"
        print "    type: tcp"
        print "  forwarder:"
        print "    nodes:"
        print "    - name: backend-45106"
        print "      addr: 127.0.0.1:2349"
        print ""
        inserted=1
      }
      { print }
    ' "$CN_RELAY_YAML" > "$relay_candidate"
    apply_cn_relay_yaml "$relay_candidate" "relay integration test" >/dev/null
    grep -q '^BUSINESS_PORTS="45100 45104 45106"$' "$CN_RELAY_CONFIG" || \
        fail "Relay manager did not synchronize BUSINESS_PORTS"

    failed_candidate="$(mktemp "$jp/.relay-failure-test.XXXXXX")"
    awk '
      /^- name:[[:space:]]*mtcp-anchor-jp[[:space:]]*$/ && !inserted {
        print "# standalone-relay: relay-45105"
        print "- name: relay-45105"
        print "  addr: :45105"
        print "  handler:"
        print "    type: tcp"
        print "    chain: chain-mtcp-jp"
        print "  listener:"
        print "    type: tcp"
        print "  forwarder:"
        print "    nodes:"
        print "    - name: backend-45105"
        print "      addr: 127.0.0.1:2348"
        print ""
        inserted=1
      }
      { print }
    ' "$CN_RELAY_YAML" > "$failed_candidate"
    set +e
    ( export MOCK_FAIL_RESTART=1; apply_cn_relay_yaml "$failed_candidate" "forced failure" >/dev/null 2>&1 )
    relay_failure_rc=$?
    set -e
    (( relay_failure_rc != 0 )) || fail "Relay failure simulation unexpectedly succeeded"
    ! grep -q '45105' "$CN_RELAY_YAML" || fail "Relay YAML rollback failed"
    ! grep -q '45105' "$CN_RUNTIME_YAML" || fail "aggregate YAML rollback failed"
    grep -q '^BUSINESS_PORTS="45100 45104 45106"$' "$CN_RELAY_CONFIG" || fail "Relay config rollback failed"

    set +e
    ( PROMPTS=(jp); PROMPT_INDEX=0; install_cn >/dev/null 2>&1 )
    reinstall_rc=$?
    set -e
    (( reinstall_rc != 0 )) || fail "active CN reinstall was not refused"

    source_tree="$integration_dir/source-tree"
    mkdir -p "$source_tree/cn"
    cp cn/mtcp.conf "$source_tree/cn/mtcp.conf"
    old_install_base="$INSTALL_BASE"
    INSTALL_BASE="$source_tree" PATHLOCK_SOURCE_TREE=1 \
        ensure_cn_port_available 12000 "$source_tree/cn/instances/default/mtcp.conf" gost-mtcp.service \
        gost-ecmp-pathlock.service || fail "source-tree canonical template was treated as a live route"
    INSTALL_BASE="$old_install_base"
    unset PATHLOCK_SOURCE_TREE

    PROMPTS=(45200); PROMPT_INDEX=0
    install_remote >/dev/null
    remote_auth="$INSTALL_BASE/remote/mtcp.auth"
    grep -q 'addr: :45200' "$INSTALL_BASE/remote/remote.yaml" || fail "Remote port render failed"
    grep -Fqx '    auther: mtcp-auth' "$INSTALL_BASE/remote/remote.yaml" || fail "Remote Relay auth is missing"
    grep -Fqx "    path: '$remote_auth'" "$INSTALL_BASE/remote/remote.yaml" || fail "Remote auth path was not rendered"
    grep -Fqx "mtcp $MTCP_AUTH_PASSWORD" "$remote_auth" || fail "Remote auth credentials are incorrect"
    [[ "$(file_mode "$remote_auth")" == 600 ]] || fail "Remote auth file permissions are not 0600"
    ! grep -Fq "$MTCP_AUTH_PASSWORD" "$INSTALL_BASE/remote/remote.yaml" || fail "Remote password leaked into YAML"
    grep -Fqx "ExecStart=$INSTALL_BASE/remote/gost -D -C $INSTALL_BASE/remote/remote.yaml" \
        "$SYSTEMD_DIR/gost-mtcp-remote.service" || fail "Remote unit render failed"
    grep -Fq "ExecStart=$integration_dir/bin/socat " "$SYSTEMD_DIR/gost-mtcp-remote-anchor.service" || \
        fail "Remote endpoint unit did not use detected socat"
    set +e
    ( PROMPTS=(); PROMPT_INDEX=0; install_remote >/dev/null 2>&1 )
    remote_reinstall_rc=$?
    set -e
    (( remote_reinstall_rc != 0 )) || fail "active Remote reinstall was not refused"
)
pass "standalone menu manages multiple CN routes, port paths, JSONL logs, isolation, and rollback"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mtcp-tests.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
cp cn/mtcp.conf "$tmp_dir/mtcp.conf"
sed -i.bak 's/^BUSINESS_PORTS=.*/BUSINESS_PORTS="12000,12002 12000"/' "$tmp_dir/mtcp.conf"
rm -f "$tmp_dir/mtcp.conf.bak"
sed -i.bak "s|/root/gost-ecmp-pathlock/cn/state|$tmp_dir/state|g" "$tmp_dir/mtcp.conf"
rm -f "$tmp_dir/mtcp.conf.bak"

# shellcheck disable=SC1091
source cn/mtcp-lib.sh
load_config "$tmp_dir/mtcp.conf"
[[ "$BUSINESS_PORTS" == "12000 12002" ]] || fail "BUSINESS_PORTS normalization failed: $BUSINESS_PORTS"

ss() {
    cat <<'SS'
ESTAB 0 0 127.0.0.1:12000 198.51.100.1:40000 users:(("gost",pid=77,fd=1))
ESTAB 0 0 127.0.0.1:12002 198.51.100.2:40001 users:(("gost",pid=77,fd=2))
ESTAB 0 0 127.0.0.1:12003 198.51.100.3:40002 users:(("gost",pid=77,fd=3))
ESTAB 0 0 127.0.0.1:12002 198.51.100.4:40003 users:(("gost",pid=88,fd=4))
SS
}
[[ "$(get_business_conn_count 77)" == 2 ]] || fail "multi-port connection count is incorrect"
pass "BUSINESS_PORTS counts all configured ports for only the target GOST PID"

cp "$tmp_dir/mtcp.conf" "$tmp_dir/legacy.conf"
sed -i.bak '/^BUSINESS_PORTS=/d' "$tmp_dir/legacy.conf"
rm -f "$tmp_dir/legacy.conf.bak"
load_config "$tmp_dir/legacy.conf"
[[ "$BUSINESS_PORTS" == "$BUSINESS_PORT" ]] || fail "legacy BUSINESS_PORT fallback failed"
pass "legacy single-port configs remain compatible"

grep -q 'PREWARM_ABORT_BUSY.*before_outer_kill\|abort_degraded_retry_if_busy "before_outer_kill"' cn/mtcp-prewarm.sh || \
    fail "prewarm final busy barrier missing"
grep -q 'DATA_PROBE_BREAKER_REARMED' cn/mtcp-watchdog.sh || fail "data probe half-open breaker missing"
grep -q 'PROCESS_RECOVERY_ATTEMPT' cn/mtcp-watchdog.sh || fail "process recovery missing"
grep -q 'RESET_ROUTE_OUTER' cn/mtcp-watchdog.sh || fail "route-local outer reset missing"
route_reset_body="$(awk '/^reset_route_rate_limited\(\)/ { emit=1 } /^run_select\(\)/ { exit } emit { print }' cn/mtcp-watchdog.sh)"
[[ "$route_reset_body" == *"kill_route_outers"* ]] || fail "route reset does not kill only route outers"
[[ "$route_reset_body" != *'systemctl restart "$UNIT"'* ]] || fail "route fault still restarts shared GOST"
pass "destructive paths isolate route outers and retain recovery breakers"

awk '/^prune_epoch_list\(\)/ { emit=1 } /^set_state\(\)/ { exit } emit { print }' \
    cn/mtcp-watchdog.sh > "$tmp_dir/breakers.sh"
(
    # shellcheck disable=SC1090
    source "$tmp_dir/breakers.sh"
    log_event() { :; }
    STATE=FAULT; LAST_PID=77; LAST_SPORT=23456
    DATA_PROBE_RESTART_WINDOW_SEC=600; DATA_PROBE_RESTART_MAX=3; DATA_PROBE_BREAKER_OPEN_SEC=600
    DATA_PROBE_RESTART_EPOCHS=""; DATA_PROBE_BREAKER_STATE=closed
    DATA_PROBE_BREAKER_UNTIL=0; DATA_PROBE_BREAKER_LOGGED=0
    allow_data_probe_restart 100
    allow_data_probe_restart 160
    allow_data_probe_restart 220
    [[ "$DATA_PROBE_BREAKER_STATE" == open && "$DATA_PROBE_BREAKER_UNTIL" == 820 ]] || \
        fail "data breaker did not arm after three attempts"
    if allow_data_probe_restart 300; then fail "open data breaker allowed a restart"; fi
    allow_data_probe_restart 821
    [[ "$DATA_PROBE_BREAKER_STATE" == open && "$DATA_PROBE_BREAKER_UNTIL" == 1421 ]] || \
        fail "data breaker half-open attempt was not rearmed"
    close_data_probe_breaker
    [[ "$DATA_PROBE_BREAKER_STATE" == closed && -z "$DATA_PROBE_RESTART_EPOCHS" ]] || \
        fail "healthy data probe did not close breaker"

    PROCESS_RECOVERY_INTERVAL_SEC=60; PROCESS_RECOVERY_WINDOW_SEC=600
    PROCESS_RECOVERY_MAX=3; PROCESS_BREAKER_OPEN_SEC=600
    PROCESS_RECOVERY_EPOCHS=""; PROCESS_BREAKER_STATE=closed
    PROCESS_BREAKER_UNTIL=0; PROCESS_BREAKER_LOGGED=0; LAST_PROCESS_RECOVERY=0
    allow_process_recovery 100
    if allow_process_recovery 120; then fail "process recovery interval was ignored"; fi
    allow_process_recovery 160
    allow_process_recovery 220
    [[ "$PROCESS_BREAKER_STATE" == open && "$PROCESS_BREAKER_UNTIL" == 820 ]] || \
        fail "process breaker did not arm after three attempts"
)
pass "data-plane and process breakers enforce window, open, and half-open behavior"

git diff --check
pass "patch has no whitespace errors"
