#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

bash -n install.sh standalone-install.sh scripts/generate-standalone.sh \
    cn/mtcp-lib.sh cn/mtcp-prewarm.sh cn/mtcp-watchdog.sh
pass "all shell files parse"

scripts/generate-standalone.sh --check >/dev/null
pass "standalone embedded payload matches canonical files"

help_output="$(bash standalone-install.sh --help)"
[[ "$help_output" == *"CN_INSTANCE"* ]] || fail "standalone help misses CN_INSTANCE"
pipe_help="$(bash -s -- --help < standalone-install.sh)"
[[ "$pipe_help" == *"CN_INSTANCE"* ]] || fail "piped standalone help failed"
pass "standalone supports file and piped execution"

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
    for mock_command in ss flock timeout socat; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$integration_dir/bin/$mock_command"
        chmod +x "$integration_dir/bin/$mock_command"
    done
    PATH="$integration_dir/bin:$PATH"

    # 只加载 standalone 的函数区，避免执行 main 和后面的嵌入 payload。
    awk '$0 == "main \"$@\"" { exit } { print }' standalone-install.sh > "$integration_dir/core.sh"
    # shellcheck disable=SC1090
    source "$integration_dir/core.sh"
    trap 'rm -rf "$integration_dir"' EXIT
    EMBEDDED_SOURCE="$ROOT_DIR/standalone-install.sh"
    INSTALL_BASE="$integration_dir/install"
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

    PROMPTS=(jp 45.142.125.253 5201 45100 45101 40); PROMPT_INDEX=0
    install_cn >/dev/null
    PROMPTS=(us 198.51.100.20 6600 45102 45103 45); PROMPT_INDEX=0
    install_cn >/dev/null

    jp="$INSTALL_BASE/cn/instances/jp"
    us="$INSTALL_BASE/cn/instances/us"
    [[ -f "$jp/cn.yaml" && -f "$jp/mtcp.conf" && -d "$jp/state" ]] || fail "jp instance missing"
    [[ -f "$us/cn.yaml" && -f "$us/mtcp.conf" && -d "$us/state" ]] || fail "us instance missing"
    grep -q 'DST="45.142.125.253"' "$jp/mtcp.conf" || fail "jp config was overwritten"
    grep -q 'DST="198.51.100.20"' "$us/mtcp.conf" || fail "us config is incorrect"
    grep -Fqx "ExecStartPre=/usr/bin/test -r $jp/cn.yaml" "$SYSTEMD_DIR/gost-mtcp-jp.service" || \
        fail "main unit does not use isolated YAML"
    grep -Fqx "ExecStart=$INSTALL_BASE/cn/mtcp-watchdog.sh $jp/mtcp.conf" \
        "$SYSTEMD_DIR/gost-mtcp-jp-watchdog.service" || fail "watchdog unit does not use isolated config"

    CN_RELAY_YAML="$jp/cn.yaml"; CN_RELAY_CONFIG="$jp/mtcp.conf"; CN_RELAY_DIR="$jp"
    CN_RELAY_UNIT="gost-mtcp-jp.service"; CN_PRIMARY_PORT=45100; CN_ANCHOR_PORT=45101
    relay_candidate="$(mktemp "$jp/.relay-test.XXXXXX")"
    awk '
      /^- name:[[:space:]]*mtcp-anchor[[:space:]]*$/ && !inserted {
        print "# standalone-relay: relay-45104"
        print "- name: relay-45104"
        print "  addr: :45104"
        print "  handler:"
        print "    type: tcp"
        print "    chain: chain-mtcp"
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
    ' "$CN_RELAY_YAML" > "$relay_candidate"
    apply_cn_relay_yaml "$relay_candidate" "relay integration test" >/dev/null
    grep -q '^BUSINESS_PORTS="45100 45104"$' "$CN_RELAY_CONFIG" || \
        fail "Relay manager did not synchronize BUSINESS_PORTS"

    failed_candidate="$(mktemp "$jp/.relay-failure-test.XXXXXX")"
    awk '
      /^- name:[[:space:]]*mtcp-anchor[[:space:]]*$/ && !inserted {
        print "# standalone-relay: relay-45105"
        print "- name: relay-45105"
        print "  addr: :45105"
        print "  handler:"
        print "    type: tcp"
        print "    chain: chain-mtcp"
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
    grep -q '^BUSINESS_PORTS="45100 45104"$' "$CN_RELAY_CONFIG" || fail "Relay config rollback failed"

    set +e
    ( PROMPTS=(jp); PROMPT_INDEX=0; install_cn >/dev/null 2>&1 )
    reinstall_rc=$?
    set -e
    (( reinstall_rc != 0 )) || fail "active CN reinstall was not refused"

    PROMPTS=(45200); PROMPT_INDEX=0
    install_remote >/dev/null
    grep -q 'addr: :45200' "$INSTALL_BASE/remote/remote.yaml" || fail "Remote port render failed"
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
pass "standalone isolates CN lines, renders Remote, and refuses active reinstalls"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mtcp-tests.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
cp cn/mtcp.conf "$tmp_dir/mtcp.conf"
sed -i.bak 's/^BUSINESS_PORTS=.*/BUSINESS_PORTS="12000,12002 12000"/' "$tmp_dir/mtcp.conf"
rm -f "$tmp_dir/mtcp.conf.bak"
sed -i.bak "s|/root/9929-gost-mtcp/cn/state|$tmp_dir/state|g" "$tmp_dir/mtcp.conf"
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
pass "destructive-path guards and recovery breakers are present"

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
