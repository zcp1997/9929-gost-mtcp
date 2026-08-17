#!/usr/bin/env bash
set -euo pipefail

# 9929-gost-mtcp 自包含安装器
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/.../standalone-install.sh | bash -s remote
#   curl -fsSL https://raw.githubusercontent.com/.../standalone-install.sh | bash -s cn
#
# 或下载后执行（也可用于 Relay 管理）：
#   wget https://raw.githubusercontent.com/.../standalone-install.sh
#   bash standalone-install.sh remote
#   bash standalone-install.sh cn
#   bash standalone-install.sh relay

VERSION="1.2.0"
INSTALL_BASE="${INSTALL_BASE:-/opt/gost-mtcp}"
GOST_VERSION="${GOST_VERSION:-v3.2.6}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
EMBEDDED_SOURCE=""
PROMPT_FD=0
PROMPT_FD_READY=0
declare -a CLEANUP_PATHS=()

cleanup() {
    local status=$? path
    for path in "${CLEANUP_PATHS[@]:-}"; do
        if [[ -n "$path" && ( -f "$path" || -d "$path" ) ]]; then
            rm -rf -- "$path" || true
        fi
    done
    return "$status"
}

trap cleanup EXIT

show_banner() {
    cat <<'BANNER'
============================================================
  9929-gost-mtcp 自包含安装器 v1.2.0

  基于 GOST MTCP 的 ECMP 低延迟路径优选方案
============================================================
BANNER
}

show_usage() {
    cat <<'USAGE'
用法：
  bash standalone-install.sh             交互选择角色
  bash standalone-install.sh cn          安装 CN 端
  bash standalone-install.sh remote      安装 Remote 端
  bash standalone-install.sh relay       交互管理 CN 端口 Relay
  bash standalone-install.sh relay list  列出 CN 端口 Relay
  bash standalone-install.sh relay add   增加 CN 端口 Relay
  bash standalone-install.sh relay remove [服务名]
                                        删除 CN 端口 Relay
  bash standalone-install.sh --help      查看帮助

环境变量：
  INSTALL_BASE               安装目录（默认 /opt/gost-mtcp）
  GOST_VERSION               GOST 版本（默认 v3.2.6）
  GITHUB_PROXY_PREFIX        GitHub 镜像前缀（CN 默认 https://ghfast.top/）
  CN_YAML_PATH               Relay 管理使用的 cn.yaml 路径（可选）
  CN_MTCP_CONFIG_PATH        Relay 管理使用的 mtcp.conf 路径（可选）
  CN_INSTANCE                Relay 管理的线路别名；安装多条线路时必须指定

示例：
  # Remote 端
  bash standalone-install.sh remote

  # CN 端（自动使用 ghfast 镜像）
  bash standalone-install.sh cn

  # CN 端强制直连 GitHub
  GITHUB_PROXY_PREFIX= bash standalone-install.sh cn

  # 增加 :12002 -> 127.0.0.1:2347 Relay
  bash standalone-install.sh relay add

  # 单命令安装（交互输入会直接读取当前终端）
  curl -fsSL https://example.com/install.sh | bash -s cn
USAGE
}

die() {
    echo "错误: $*" >&2
    exit 1
}

check_root() {
    [[ "$EUID" -eq 0 ]] || die "需要 root 权限，请使用 sudo 或 su"
}

check_command() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null || die "缺少命令: $cmd"
}

# bash 从管道或 process substitution 读取脚本时，$0 不是可重复读取的普通文件。
# main 执行时脚本尾部尚未被解释，先保存嵌入区，供后续多次提取。
prepare_embedded_source() {
    local script_source="${BASH_SOURCE[0]:-}" tmp_source

    if [[ -n "$script_source" && -f "$script_source" ]]; then
        EMBEDDED_SOURCE="$script_source"
        return
    fi

    tmp_source="$(mktemp)"
    CLEANUP_PATHS+=("$tmp_source")
    if [[ -n "$script_source" && -r "$script_source" ]]; then
        sed -n '/^### BEGIN /,$p' "$script_source" > "$tmp_source"
    else
        sed -n '/^### BEGIN /,$p' <&0 > "$tmp_source"
    fi
    grep -q '^### BEGIN REMOTE_YAML ###$' "$tmp_source" || \
        die "无法读取安装器内嵌文件；请重新下载安装脚本"
    EMBEDDED_SOURCE="$tmp_source"
}

prepare_prompt_input() {
    (( PROMPT_FD_READY == 0 )) || return 0
    if [[ -r /dev/tty && -w /dev/tty ]] && exec 9<>/dev/tty; then
        PROMPT_FD=9
    else
        PROMPT_FD=0
    fi
    PROMPT_FD_READY=1
}

prompt_read() {
    local output_var="$1" prompt="$2" value
    prepare_prompt_input
    IFS= read -r -u "$PROMPT_FD" -p "$prompt" value || return 1
    printf -v "$output_var" '%s' "$value"
}

# 从脚本末尾提取嵌入的文件
extract_embedded() {
    local marker="$1"
    sed -n "/^### BEGIN ${marker} ###$/,/^### END ${marker} ###$/p" "$EMBEDDED_SOURCE" | sed '1d;$d'
}

normalize_role() {
    case "${1:-}" in
        1|cn|CN) echo "cn" ;;
        2|remote|REMOTE|Remote) echo "remote" ;;
        3|relay|RELAY|Relay) echo "relay" ;;
        *) return 1 ;;
    esac
}

select_role_interactively() {
    cat <<'MENU'

请选择当前服务器的角色：

  1) CN      中国大陆入口端（接收业务、路径优选）
  2) Remote  境外中转端（监听 MTCP、连接后端）
  3) Relay   管理已安装 CN 的端口转发
  q) 退出

建议先安装 Remote，再安装 CN。
MENU

    local choice
    while :; do
        prompt_read choice "请选择 [1/2/3/q]: " || die "未选择角色"
        case "$choice" in
            q|Q|quit|exit) echo "已取消。"; exit 0 ;;
            1|2|3)
                SELECTED_ROLE=$(normalize_role "$choice")
                [[ "$SELECTED_ROLE" == "relay" ]] && return
                prompt_read confirm "确认安装 $SELECTED_ROLE 端？[Y/n]: " || die "未确认安装"
                case "${confirm:-y}" in
                    y|Y|yes|YES|"") return ;;
                    *) continue ;;
                esac
                ;;
            "") ;;
            *) echo "无效输入" >&2 ;;
        esac
    done
}

download_release_file() {
    local direct_url="$1" output="$2" proxy_url

    if [[ -n "$GITHUB_PROXY_PREFIX" ]]; then
        proxy_url="${GITHUB_PROXY_PREFIX%/}/${direct_url}"
        if curl -fsSL --retry 2 --connect-timeout 10 -o "$output" "$proxy_url"; then
            return 0
        fi
        echo "镜像下载失败，尝试直连 GitHub ..." >&2
    fi

    curl -fsSL --retry 2 --connect-timeout 10 -o "$output" "$direct_url"
}

download_gost() {
    local role="$1" dest_dir="$2"

    # CN 默认使用镜像，Remote 默认直连
    if [[ "$role" == "cn" && -z "${GITHUB_PROXY_PREFIX+x}" ]]; then
        GITHUB_PROXY_PREFIX="https://ghfast.top/"
    else
        GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX:-}"
    fi

    local arch os version release_tag tarball base_url checksum_entry
    arch="$(uname -m)"
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *) die "不支持的架构: $arch" ;;
    esac

    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    [[ "$os" == "linux" ]] || die "仅支持 Linux"

    version="${GOST_VERSION#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || \
        die "GOST_VERSION 格式无效: $GOST_VERSION"
    release_tag="v${version}"
    tarball="gost_${version}_${os}_${arch}.tar.gz"
    base_url="https://github.com/go-gost/gost/releases/download/${release_tag}"

    echo "下载 GOST ${release_tag} ..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CLEANUP_PATHS+=("$tmp_dir")

    download_release_file "${base_url}/${tarball}" "$tmp_dir/$tarball" || \
        die "下载失败: $tarball"
    download_release_file "${base_url}/checksums.txt" "$tmp_dir/checksums.txt" || \
        die "下载 checksums.txt 失败"

    echo "校验 SHA256..."
    (
        cd "$tmp_dir"
        checksum_entry="$(awk -v file="$tarball" '$2 == file || $2 == "*" file { print; exit }' checksums.txt)"
        [[ -n "$checksum_entry" ]] || die "checksums.txt 中缺少 $tarball"
        if command -v sha256sum &>/dev/null; then
            printf '%s\n' "$checksum_entry" | sha256sum -c - || die "校验失败"
        elif command -v shasum &>/dev/null; then
            printf '%s\n' "$checksum_entry" | shasum -a 256 -c - || die "校验失败"
        else
            die "缺少 sha256sum 或 shasum"
        fi
    )

    echo "解压..."
    tar -xzf "$tmp_dir/$tarball" -C "$tmp_dir"
    local gost_tmp
    gost_tmp="$(mktemp "$dest_dir/.gost.XXXXXX")"
    CLEANUP_PATHS+=("$gost_tmp")
    install -m 755 "$tmp_dir/gost" "$gost_tmp"
    mv -f "$gost_tmp" "$dest_dir/gost"
    echo "✓ GOST 已安装到 $dest_dir/gost"
}

valid_ipv4() {
    local value="$1" octet
    local -a octets
    IFS=. read -r -a octets <<< "$value"
    (( ${#octets[@]} == 4 )) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

ensure_units_inactive() {
    local label="$1" unit
    shift
    local -a active=()
    for unit in "$@"; do
        "$SYSTEMCTL_BIN" is-active --quiet "$unit" >/dev/null 2>&1 && active+=("$unit")
    done
    if (( ${#active[@]} > 0 )); then
        die "$label 仍在运行（${active[*]}）。为避免运行进程与新配置错配，请先停止这些 unit 后再重装"
    fi
}

ensure_cn_port_available() {
    local wanted="$1" current_config="$2" config values value
    for config in "$INSTALL_BASE"/cn/instances/*/mtcp.conf "$INSTALL_BASE"/cn/mtcp.conf; do
        [[ -f "$config" && "$config" != "$current_config" ]] || continue
        values="$(awk -F= '
            $1 == "BUSINESS_PORT" || $1 == "BUSINESS_PORTS" || $1 == "ANCHOR_PORT" {
                value=substr($0,index($0,"=")+1); gsub(/^[\047\"]|[\047\"]$/, "", value); print value
            }
        ' "$config")"
        values="${values//,/ }"
        for value in $values; do
            [[ "$value" == "$wanted" ]] && die "本机端口 $wanted 已被另一条线路配置占用: $config"
        done
    done
    if ss -ltnH "sport = :$wanted" 2>/dev/null | grep -q .; then
        die "本机端口 $wanted 已被其他进程监听"
    fi
}

install_remote() {
    echo; echo "==> 开始安装 Remote 端"; echo
    check_command curl; check_command tar; check_command "$SYSTEMCTL_BIN"; check_command socat

    local remote_dir="$INSTALL_BASE/remote" main_unit="gost-mtcp-remote.service"
    local anchor_unit="gost-mtcp-remote-anchor.service" mtcp_port socat_bin
    local config_tmp main_tmp anchor_tmp
    ensure_units_inactive "Remote" "$main_unit" "$anchor_unit"
    mkdir -p "$remote_dir" "$SYSTEMD_DIR"
    socat_bin="$(command -v socat)"

    prompt_read mtcp_port "Remote MTCP 监听端口 [6600]: " || die "未输入 MTCP 端口"
    mtcp_port="${mtcp_port:-6600}"
    valid_port "$mtcp_port" || die "端口无效"
    mtcp_port=$((10#$mtcp_port))
    [[ "$mtcp_port" != 12346 ]] || die "12346 被 Anchor endpoint 占用"

    download_gost remote "$remote_dir"
    config_tmp="$(mktemp "$remote_dir/.remote.yaml.XXXXXX")"; CLEANUP_PATHS+=("$config_tmp")
    extract_embedded REMOTE_YAML | awk -v addr=":$mtcp_port" '
        /^[[:space:]]*-[[:space:]]name:[[:space:]]*mtcp-server[[:space:]]*$/ { target=1 }
        target && /^[[:space:]]*addr:[[:space:]]*/ { sub(/addr:.*/, "addr: " addr); target=0; updated++ }
        { print }
        END { if (updated != 1) exit 42 }
    ' > "$config_tmp" || die "canonical Remote 配置结构不符合预期"
    chmod 0644 "$config_tmp"; mv -f "$config_tmp" "$remote_dir/remote.yaml"

    main_tmp="$(mktemp "$SYSTEMD_DIR/.gost-mtcp-remote.XXXXXX")"
    anchor_tmp="$(mktemp "$SYSTEMD_DIR/.gost-mtcp-remote-anchor.XXXXXX")"
    CLEANUP_PATHS+=("$main_tmp" "$anchor_tmp")
    extract_embedded REMOTE_MAIN_SERVICE | sed \
        -e "s|/root/9929-gost-mtcp/remote|$remote_dir|g" \
        > "$main_tmp"
    extract_embedded REMOTE_ANCHOR_SERVICE | sed \
        -e "s|9929-gost-mtcp-remote.service|$main_unit|g" \
        -e "s|/usr/bin/socat|$socat_bin|g" \
        > "$anchor_tmp"
    chmod 0644 "$main_tmp" "$anchor_tmp"
    mv -f "$main_tmp" "$SYSTEMD_DIR/$main_unit"
    mv -f "$anchor_tmp" "$SYSTEMD_DIR/$anchor_unit"

    "$SYSTEMCTL_BIN" daemon-reload
    "$SYSTEMCTL_BIN" enable "$main_unit" "$anchor_unit"
    "$SYSTEMCTL_BIN" restart "$main_unit" "$anchor_unit"
    "$SYSTEMCTL_BIN" is-active --quiet "$main_unit" || die "$main_unit 启动失败"
    "$SYSTEMCTL_BIN" is-active --quiet "$anchor_unit" || die "$anchor_unit 启动失败"

    cat <<DONE

============================================================
  Remote 端安装完成
============================================================
MTCP 监听端口: $mtcp_port
配置文件: $remote_dir/remote.yaml
服务: $main_unit, $anchor_unit
重要: 请只允许 CN 公网 IP 访问 $mtcp_port/tcp
============================================================
DONE
}

install_cn() {
    echo; echo "==> 开始安装 CN 端"; echo
    check_command curl; check_command tar; check_command "$SYSTEMCTL_BIN"
    check_command ss; check_command flock; check_command timeout

    local cn_dir="$INSTALL_BASE/cn" remote_alias remote_ip remote_port business_port anchor_port rtt_threshold
    local unit_prefix main_unit anchor_unit watchdog_unit instance_dir state_dir
    local yaml_tmp conf_tmp lib_tmp prewarm_tmp watchdog_tmp main_tmp anchor_tmp watchdog_unit_tmp
    mkdir -p "$cn_dir/instances"

    echo "配置参数:"; echo
    prompt_read remote_alias "Remote 线路别名（如 de、us，回车=default）: " || die "未输入线路别名"
    remote_alias="${remote_alias:-default}"
    [[ "$remote_alias" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "线路别名无效"
    case "$remote_alias" in anchor|watchdog|*-anchor|*-watchdog) die "线路别名使用了保留后缀" ;; esac

    unit_prefix="gost-mtcp"
    [[ "$remote_alias" != default ]] && unit_prefix="gost-mtcp-$remote_alias"
    main_unit="$unit_prefix.service"; anchor_unit="$unit_prefix-anchor.service"
    watchdog_unit="$unit_prefix-watchdog.service"
    instance_dir="$cn_dir/instances/$remote_alias"; state_dir="$instance_dir/state"
    ensure_units_inactive "CN 线路 $remote_alias" "$watchdog_unit" "$anchor_unit" "$main_unit"
    mkdir -p "$state_dir" "$SYSTEMD_DIR"

    while :; do
        prompt_read remote_ip "Remote IPv4 地址: " || die "未输入 Remote IPv4 地址"
        valid_ipv4 "$remote_ip" && break
        echo "  无效的 IPv4 地址" >&2
    done
    prompt_read remote_port "Remote MTCP 端口 [6600]: " || die "未输入 Remote MTCP 端口"
    prompt_read business_port "CN 业务监听端口 [12000]: " || die "未输入 CN 业务监听端口"
    prompt_read anchor_port "CN Anchor 监听端口 [12001]: " || die "未输入 CN Anchor 监听端口"
    prompt_read rtt_threshold "RTT 快路阈值（ms）[40]: " || die "未输入 RTT 阈值"
    remote_port="${remote_port:-6600}"; business_port="${business_port:-12000}"
    anchor_port="${anchor_port:-12001}"; rtt_threshold="${rtt_threshold:-40}"
    valid_port "$remote_port" && valid_port "$business_port" && valid_port "$anchor_port" || die "端口必须为 1-65535"
    remote_port=$((10#$remote_port)); business_port=$((10#$business_port)); anchor_port=$((10#$anchor_port))
    [[ "$business_port" != "$anchor_port" ]] || die "业务端口不能与 Anchor 端口相同"
    [[ "$rtt_threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "RTT 阈值无效"
    ensure_cn_port_available "$business_port" "$instance_dir/mtcp.conf"
    ensure_cn_port_available "$anchor_port" "$instance_dir/mtcp.conf"

    download_gost cn "$cn_dir"

    yaml_tmp="$(mktemp "$instance_dir/.cn.yaml.XXXXXX")"
    conf_tmp="$(mktemp "$instance_dir/.mtcp.conf.XXXXXX")"
    CLEANUP_PATHS+=("$yaml_tmp" "$conf_tmp")
    extract_embedded CN_YAML | awk -v business=":$business_port" \
        -v anchor="127.0.0.1:$anchor_port" -v remote="$remote_ip:$remote_port" '
        /^[[:space:]]*-[[:space:]]name:[[:space:]]*tcp-entry[[:space:]]*$/ { target="business" }
        /^[[:space:]]*-[[:space:]]name:[[:space:]]*mtcp-anchor[[:space:]]*$/ { target="anchor" }
        /^chains:[[:space:]]*$/ { chains=1 }
        chains && /^[[:space:]]*addr:[[:space:]]*/ { sub(/addr:.*/, "addr: " remote); chains=0; r++ }
        target != "" && /^[[:space:]]*addr:[[:space:]]*/ {
            value=(target == "business" ? business : anchor); sub(/addr:.*/, "addr: " value)
            if (target == "business") b++; else a++; target=""
        }
        { print }
        END { if (a != 1 || b != 1 || r != 1) exit 42 }
    ' > "$yaml_tmp" || die "canonical CN YAML 结构不符合预期"

    extract_embedded CN_MTCP_CONF | awk -v main="$main_unit" -v anchor_unit="$anchor_unit" \
        -v remote="$remote_ip" -v remote_port="$remote_port" -v business="$business_port" \
        -v anchor_port="$anchor_port" -v rtt="$rtt_threshold" -v state="$state_dir" '
        BEGIN {
            v["UNIT"]=main; v["ANCHOR_UNIT"]=anchor_unit; v["DST"]=remote; v["PORT"]=remote_port
            v["BUSINESS_PORT"]=business; v["BUSINESS_PORTS"]=business; v["ANCHOR_HOST"]="127.0.0.1"
            v["ANCHOR_PORT"]=anchor_port; v["ACCEPT_RTT_MS"]=rtt; v["STATE_DIR"]=state
            v["STATE_FILE"]=state "/runtime.state"; v["STATUS_JSON"]=state "/status.json"
            v["EVENT_FILE"]=state "/events.jsonl"
        }
        { key=$0; sub(/=.*/, "", key); if (key in v) { print key "=\"" v[key] "\""; seen[key]++; next } print }
        END { for (key in v) if (seen[key] != 1) exit 42 }
    ' > "$conf_tmp" || die "canonical CN 配置结构不符合预期"
    chmod 0644 "$yaml_tmp" "$conf_tmp"
    mv -f "$yaml_tmp" "$instance_dir/cn.yaml"; mv -f "$conf_tmp" "$instance_dir/mtcp.conf"

    lib_tmp="$(mktemp "$cn_dir/.mtcp-lib.XXXXXX")"
    prewarm_tmp="$(mktemp "$cn_dir/.mtcp-prewarm.XXXXXX")"
    watchdog_tmp="$(mktemp "$cn_dir/.mtcp-watchdog.XXXXXX")"
    CLEANUP_PATHS+=("$lib_tmp" "$prewarm_tmp" "$watchdog_tmp")
    extract_embedded CN_LIB | sed "s|/root/9929-gost-mtcp/cn|$cn_dir|g" > "$lib_tmp"
    extract_embedded CN_PREWARM | sed "s|/root/9929-gost-mtcp/cn|$cn_dir|g" > "$prewarm_tmp"
    extract_embedded CN_WATCHDOG | sed "s|/root/9929-gost-mtcp/cn|$cn_dir|g" > "$watchdog_tmp"
    chmod 0755 "$lib_tmp" "$prewarm_tmp" "$watchdog_tmp"
    mv -f "$lib_tmp" "$cn_dir/mtcp-lib.sh"; mv -f "$prewarm_tmp" "$cn_dir/mtcp-prewarm.sh"
    mv -f "$watchdog_tmp" "$cn_dir/mtcp-watchdog.sh"

    main_tmp="$(mktemp "$SYSTEMD_DIR/.${unit_prefix}.XXXXXX")"
    anchor_tmp="$(mktemp "$SYSTEMD_DIR/.${unit_prefix}-anchor.XXXXXX")"
    watchdog_unit_tmp="$(mktemp "$SYSTEMD_DIR/.${unit_prefix}-watchdog.XXXXXX")"
    CLEANUP_PATHS+=("$main_tmp" "$anchor_tmp" "$watchdog_unit_tmp")
    extract_embedded CN_MAIN_SERVICE | awk -v cn="$cn_dir" -v wd="$instance_dir" -v yaml="$instance_dir/cn.yaml" '
        /^WorkingDirectory=/ { print "WorkingDirectory=" wd; next }
        /^ExecStartPre=\/usr\/bin\/test -x / { print "ExecStartPre=/usr/bin/test -x " cn "/gost"; next }
        /^ExecStartPre=\/usr\/bin\/test -r / { print "ExecStartPre=/usr/bin/test -r " yaml; next }
        /^ExecStart=/ { print "ExecStart=" cn "/gost -D -C " yaml; next }
        { print }
    ' > "$main_tmp"
    extract_embedded CN_ANCHOR_SERVICE | sed \
        -e "s|9929-gost-mtcp.service|$main_unit|g" \
        -e "s|/dev/tcp/127.0.0.1/12001|/dev/tcp/127.0.0.1/$anchor_port|g" > "$anchor_tmp"
    extract_embedded CN_WATCHDOG_SERVICE | awk -v canonical="9929-gost-mtcp.service" -v main="$main_unit" \
        -v root="/root/9929-gost-mtcp/cn" -v cn="$cn_dir" -v wd="$instance_dir" \
        -v config="$instance_dir/mtcp.conf" '
        function repl(s,a,b) { while ((p=index(s,a))>0) s=substr(s,1,p-1) b substr(s,p+length(a)); return s }
        { line=repl($0,canonical,main); line=repl(line,root "/mtcp.conf",config); line=repl(line,root,cn)
          if (line ~ /^WorkingDirectory=/) line="WorkingDirectory=" wd; print line }
    ' > "$watchdog_unit_tmp"
    chmod 0644 "$main_tmp" "$anchor_tmp" "$watchdog_unit_tmp"
    mv -f "$main_tmp" "$SYSTEMD_DIR/$main_unit"
    mv -f "$anchor_tmp" "$SYSTEMD_DIR/$anchor_unit"
    mv -f "$watchdog_unit_tmp" "$SYSTEMD_DIR/$watchdog_unit"

    "$SYSTEMCTL_BIN" daemon-reload
    "$SYSTEMCTL_BIN" enable "$main_unit" "$watchdog_unit"
    "$SYSTEMCTL_BIN" restart "$main_unit" "$watchdog_unit"
    "$SYSTEMCTL_BIN" is-active --quiet "$main_unit" || die "$main_unit 启动失败"
    "$SYSTEMCTL_BIN" is-active --quiet "$watchdog_unit" || die "$watchdog_unit 启动失败"

    cat <<DONE

============================================================
  CN 端安装完成
============================================================
线路: $remote_alias    Remote: $remote_ip:$remote_port
业务端口: $business_port    RTT 阈值: ${rtt_threshold}ms
配置: $instance_dir/cn.yaml, $instance_dir/mtcp.conf
状态: $state_dir/status.json
服务: $main_unit, $watchdog_unit
Relay 管理: CN_INSTANCE=$remote_alias bash standalone-install.sh relay
============================================================
DONE
}

valid_port() {
    local value="${1:-}" number
    [[ "$value" =~ ^[0-9]+$ && ${#value} -le 5 ]] || return 1
    number=$((10#$value))
    (( number >= 1 && number <= 65535 ))
}

read_config_value() {
    local file="$1" key="$2"
    awk -F= -v wanted="$key" '
        $1 == wanted {
            value = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            gsub(/^['\''\"]|['\''\"]$/, "", value)
            print value
            exit
        }
    ' "$file"
}

# 输出：service_name<TAB>listen_addr<TAB>backend_addr<TAB>chain_name。
cn_relay_rows() {
    local yaml="$1"
    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function flush_service() {
            if (service_name != "") {
                printf "%s\t%s\t%s\t%s\n", service_name, listen_addr, backend_addr, chain_name
            }
            service_name = ""
            listen_addr = ""
            backend_addr = ""
            chain_name = ""
            address_count = 0
        }
        /^services:[[:space:]]*$/ { in_services = 1; next }
        /^chains:[[:space:]]*$/ { flush_service(); in_services = 0; exit }
        in_services && /^- name:[[:space:]]*/ {
            flush_service()
            service_name = $0
            sub(/^- name:[[:space:]]*/, "", service_name)
            service_name = trim(service_name)
            next
        }
        in_services && service_name != "" && /^[[:space:]]+addr:[[:space:]]*/ {
            value = $0
            sub(/^[[:space:]]+addr:[[:space:]]*/, "", value)
            value = trim(value)
            address_count++
            if (address_count == 1) listen_addr = value
            else if (address_count == 2) backend_addr = value
        }
        in_services && service_name != "" && /^[[:space:]]+chain:[[:space:]]*/ {
            chain_name = $0
            sub(/^[[:space:]]+chain:[[:space:]]*/, "", chain_name)
            chain_name = trim(chain_name)
        }
        END { if (in_services) flush_service() }
    ' "$yaml"
}

resolve_cn_relay_context() {
    if [[ -n "${CN_YAML_PATH:-}" ]]; then
        CN_RELAY_YAML="$CN_YAML_PATH"
    elif [[ -n "${CN_INSTANCE:-}" ]]; then
        [[ "$CN_INSTANCE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "CN_INSTANCE 无效"
        CN_RELAY_YAML="$INSTALL_BASE/cn/instances/$CN_INSTANCE/cn.yaml"
    elif [[ -r "$INSTALL_BASE/cn/cn.yaml" ]]; then
        # 兼容 v1.1 及更早的单目录安装。
        CN_RELAY_YAML="$INSTALL_BASE/cn/cn.yaml"
    else
        local path
        local -a candidates=()
        for path in "$INSTALL_BASE"/cn/instances/*/cn.yaml; do
            [[ -r "$path" ]] && candidates+=("$path")
        done
        if (( ${#candidates[@]} == 1 )); then
            CN_RELAY_YAML="${candidates[0]}"
        elif (( ${#candidates[@]} > 1 )); then
            echo "检测到多条 CN 线路：" >&2
            for path in "${candidates[@]}"; do echo "  $(basename "$(dirname "$path")")" >&2; done
            die "请用 CN_INSTANCE=<线路别名> 指定 Relay 管理目标"
        else
            CN_RELAY_YAML="$INSTALL_BASE/cn.yaml"
        fi
    fi
    if [[ -n "${CN_MTCP_CONFIG_PATH:-}" ]]; then
        CN_RELAY_CONFIG="$CN_MTCP_CONFIG_PATH"
    else
        CN_RELAY_CONFIG="$(dirname "$CN_RELAY_YAML")/mtcp.conf"
    fi
    CN_RELAY_DIR="$(dirname "$CN_RELAY_YAML")"
    [[ -r "$CN_RELAY_YAML" ]] || die "CN 配置不存在: $CN_RELAY_YAML"
    [[ -r "$CN_RELAY_CONFIG" ]] || die "CN Watchdog 配置不存在: $CN_RELAY_CONFIG"

    CN_RELAY_UNIT="$(read_config_value "$CN_RELAY_CONFIG" UNIT)"
    CN_PRIMARY_PORT="$(read_config_value "$CN_RELAY_CONFIG" BUSINESS_PORT)"
    CN_ANCHOR_PORT="$(read_config_value "$CN_RELAY_CONFIG" ANCHOR_PORT)"
    [[ "$CN_RELAY_UNIT" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || \
        die "mtcp.conf 中 UNIT 无效: ${CN_RELAY_UNIT:-<空>}"
    valid_port "$CN_PRIMARY_PORT" || die "mtcp.conf 中 BUSINESS_PORT 无效"
    valid_port "$CN_ANCHOR_PORT" || die "mtcp.conf 中 ANCHOR_PORT 无效"
    "$SYSTEMCTL_BIN" cat "$CN_RELAY_UNIT" >/dev/null 2>&1 || \
        die "systemd unit 不存在: ${CN_RELAY_UNIT}（请先修正 mtcp.conf 的 UNIT）"
}

cn_business_ports() {
    local yaml="$1" name listen backend chain port ports="" seen=" "
    while IFS=$'\t' read -r name listen backend chain; do
        [[ "$name" != "mtcp-anchor" && "$chain" == "chain-mtcp" ]] || continue
        [[ "$listen" =~ ^:([0-9]+)$ ]] || continue
        port="${BASH_REMATCH[1]}"
        valid_port "$port" || continue
        if [[ "$seen" != *" $port "* ]]; then
            ports="${ports:+$ports }$port"; seen+="$port "
        fi
    done < <(cn_relay_rows "$yaml")
    printf '%s\n' "$ports"
}

list_cn_relays() {
    local name listen backend chain kind count=0
    printf '\n%-24s %-18s %-28s %s\n' "SERVICE" "LISTEN" "BACKEND" "TYPE"
    printf '%-24s %-18s %-28s %s\n' "------------------------" "------------------" \
        "----------------------------" "-------"
    while IFS=$'\t' read -r name listen backend chain; do
        [[ -n "$name" ]] || continue
        if [[ "$name" == "mtcp-anchor" || "$listen" == "127.0.0.1:$CN_ANCHOR_PORT" ]]; then
            kind="anchor"
        elif [[ "$listen" == ":$CN_PRIMARY_PORT" ]]; then
            kind="primary"
        elif [[ "$chain" == "chain-mtcp" ]]; then
            kind="relay"
        else
            kind="other"
        fi
        printf '%-24s %-18s %-28s %s\n' "$name" "$listen" "${backend:--}" "$kind"
        count=$((count + 1))
    done < <(cn_relay_rows "$CN_RELAY_YAML")
    (( count > 0 )) || echo "未找到 services 配置。"
    echo
}

validate_backend_addr() {
    local value="$1" port
    if [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:([0-9]+)$ ]]; then
        port="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\[[0-9A-Fa-f:]+\]:([0-9]+)$ ]]; then
        port="${BASH_REMATCH[1]}"
    else
        return 1
    fi
    valid_port "$port"
}

validate_cn_relay_yaml() {
    local yaml="$1" name listen backend chain anchor_count=0 primary_count=0
    local seen_names=$'\n' seen_listens=$'\n'

    while IFS=$'\t' read -r name listen backend chain; do
        [[ -n "$name" && -n "$listen" ]] || return 1
        [[ "$seen_names" != *$'\n'"$name"$'\n'* ]] || return 1
        [[ "$seen_listens" != *$'\n'"$listen"$'\n'* ]] || return 1
        seen_names+="$name"$'\n'
        seen_listens+="$listen"$'\n'
        [[ "$name" == "mtcp-anchor" ]] && anchor_count=$((anchor_count + 1))
        [[ "$listen" == ":$CN_PRIMARY_PORT" ]] && primary_count=$((primary_count + 1))
        if [[ "$chain" == "chain-mtcp" && -z "$backend" ]]; then return 1; fi
    done < <(cn_relay_rows "$yaml")

    (( anchor_count == 1 && primary_count == 1 )) || return 1
    grep -Eq '^- name:[[:space:]]*chain-mtcp[[:space:]]*$' "$yaml"
}

apply_cn_relay_yaml() {
    local candidate="$1" action="$2" backup failed config_backup config_failed
    local config_candidate ports stamp restart_ok=0
    if ! validate_cn_relay_yaml "$candidate"; then
        rm -f "$candidate"
        die "生成的 cn.yaml 未通过结构检查，原配置未修改"
    fi

    ports="$(cn_business_ports "$candidate")"
    [[ " $ports " == *" $CN_PRIMARY_PORT "* ]] || {
        rm -f "$candidate"
        die "生成的 BUSINESS_PORTS 未包含主业务端口，原配置未修改"
    }
    [[ " $ports " != *" $CN_ANCHOR_PORT "* ]] || {
        rm -f "$candidate"
        die "生成的 BUSINESS_PORTS 错误包含 Anchor 端口，原配置未修改"
    }
    config_candidate="$(mktemp "$CN_RELAY_DIR/.mtcp.conf.relay.XXXXXX")"
    if ! awk -v ports="$ports" '
        /^BUSINESS_PORTS=/ { print "BUSINESS_PORTS=\"" ports "\""; updated=1; next }
        { print }
        END { if (!updated) print "BUSINESS_PORTS=\"" ports "\"" }
    ' "$CN_RELAY_CONFIG" > "$config_candidate"; then
        rm -f "$candidate" "$config_candidate"
        die "无法生成 BUSINESS_PORTS 配置，原配置未修改"
    fi

    stamp="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    backup="${CN_RELAY_YAML}.bak.$stamp"
    failed="${CN_RELAY_YAML}.failed.$stamp"
    config_backup="${CN_RELAY_CONFIG}.bak.$stamp"
    config_failed="${CN_RELAY_CONFIG}.failed.$stamp"
    cp -p "$CN_RELAY_YAML" "$backup"
    cp -p "$CN_RELAY_CONFIG" "$config_backup"
    chmod 0644 "$candidate" "$config_candidate"
    if ! mv -f "$candidate" "$CN_RELAY_YAML" || ! mv -f "$config_candidate" "$CN_RELAY_CONFIG"; then
        cp -p "$backup" "$CN_RELAY_YAML" >/dev/null 2>&1 || true
        cp -p "$config_backup" "$CN_RELAY_CONFIG" >/dev/null 2>&1 || true
        rm -f "$candidate" "$config_candidate"
        die "无法同时替换 cn.yaml 与 mtcp.conf；已尝试恢复原配置"
    fi

    echo "正在重启 ${CN_RELAY_UNIT}；现有业务连接会中断并由 Watchdog 重新 Prewarm。"
    if "$SYSTEMCTL_BIN" restart "$CN_RELAY_UNIT"; then
        sleep 1
        if "$SYSTEMCTL_BIN" is-active --quiet "$CN_RELAY_UNIT"; then
            restart_ok=1
        fi
    fi

    if (( restart_ok == 1 )); then
        echo "✓ $action"
        echo "Watchdog BUSINESS_PORTS 已同步为: $ports"
        echo "备份: $backup, $config_backup"
        return 0
    fi

    echo "GOST 重启失败，正在回滚 $CN_RELAY_YAML" >&2
    cp -p "$CN_RELAY_YAML" "$failed"
    cp -p "$CN_RELAY_CONFIG" "$config_failed"
    cp -p "$backup" "$CN_RELAY_YAML"
    cp -p "$config_backup" "$CN_RELAY_CONFIG"
    "$SYSTEMCTL_BIN" restart "$CN_RELAY_UNIT" >/dev/null 2>&1 || true
    die "Relay 修改未生效；YAML 与 mtcp.conf 均已回滚。失败配置: $failed, $config_failed"
}

add_cn_relay() {
    local listen_port backend service_name default_name
    local existing_name existing_listen existing_backend existing_chain candidate confirm

    while :; do
        prompt_read listen_port "新增 CN 监听端口（例如 12002）: " || die "未输入监听端口"
        valid_port "$listen_port" && break
        echo "端口必须是 1-65535 之间的数字。" >&2
    done
    listen_port=$((10#$listen_port))
    [[ "$listen_port" != "$CN_PRIMARY_PORT" ]] || die "$listen_port 是受保护的主业务端口"
    [[ "$listen_port" != "$CN_ANCHOR_PORT" ]] || die "$listen_port 是受保护的 Anchor 端口"

    while :; do
        prompt_read backend "Remote 后端地址（例如 127.0.0.1:2347）: " || die "未输入后端地址"
        validate_backend_addr "$backend" && break
        echo "后端地址格式无效，请使用 host:port 或 [IPv6]:port。" >&2
    done
    default_name="relay-$listen_port"
    prompt_read service_name "Relay 服务名 [$default_name]: " || die "未输入服务名"
    service_name="${service_name:-$default_name}"
    [[ "$service_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || \
        die "服务名只能包含字母、数字、下划线和连字符"
    [[ "$service_name" != "mtcp-anchor" ]] || die "mtcp-anchor 是保留服务名"

    while IFS=$'\t' read -r existing_name existing_listen existing_backend existing_chain; do
        [[ "$existing_name" != "$service_name" ]] || die "服务名已存在: $service_name"
        [[ "$existing_listen" != ":$listen_port" ]] || die "监听端口已在 cn.yaml 中使用: $listen_port"
    done < <(cn_relay_rows "$CN_RELAY_YAML")
    if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$listen_port" 2>/dev/null | grep -q .; then
        die "本机端口已被其他进程监听: $listen_port"
    fi

    echo "将增加: :$listen_port -> ${backend}（service=${service_name}，共用 chain-mtcp）"
    prompt_read confirm "确认修改并重启 ${CN_RELAY_UNIT}？[y/N]: " || die "操作已取消"
    case "$confirm" in y|Y|yes|YES) ;; *) echo "已取消。"; return 0 ;; esac

    candidate="$(mktemp "$CN_RELAY_DIR/.cn.yaml.relay.XXXXXX")"
    if ! awk -v relay_name="$service_name" -v listen_port="$listen_port" \
        -v backend_name="backend-$listen_port" -v backend_addr="$backend" '
        function emit_relay() {
            print "# standalone-relay: " relay_name
            print "- name: " relay_name
            print "  addr: :" listen_port
            print "  handler:"
            print "    type: tcp"
            print "    chain: chain-mtcp"
            print "  listener:"
            print "    type: tcp"
            print "  forwarder:"
            print "    nodes:"
            print "    - name: " backend_name
            print "      addr: " backend_addr
            print ""
        }
        /^- name:[[:space:]]*mtcp-anchor[[:space:]]*$/ && !inserted {
            emit_relay()
            inserted = 1
        }
        { print }
        END { if (!inserted) exit 42 }
    ' "$CN_RELAY_YAML" > "$candidate"; then
        rm -f "$candidate"
        die "没有找到 mtcp-anchor，拒绝修改未知结构的 cn.yaml"
    fi
    apply_cn_relay_yaml "$candidate" "已增加 :$listen_port -> $backend"
}

remove_cn_relay() {
    local requested="${1:-}" name listen backend chain line confirm candidate
    local -a candidates=()

    while IFS=$'\t' read -r name listen backend chain; do
        [[ "$name" == "mtcp-anchor" || "$listen" == ":$CN_PRIMARY_PORT" || \
           "$listen" == "127.0.0.1:$CN_ANCHOR_PORT" ]] && continue
        [[ "$chain" == "chain-mtcp" ]] || continue
        candidates+=("$name"$'\t'"$listen"$'\t'"$backend"$'\t'"$chain")
    done < <(cn_relay_rows "$CN_RELAY_YAML")
    (( ${#candidates[@]} > 0 )) || die "没有可删除的额外 Relay"

    if [[ -z "$requested" ]]; then
        echo "可删除的 Relay："
        local index=1 choice
        for line in "${candidates[@]}"; do
            IFS=$'\t' read -r name listen backend chain <<< "$line"
            printf '  %d) %s  %s -> %s\n' "$index" "$name" "$listen" "$backend"
            index=$((index + 1))
        done
        prompt_read choice "请选择编号: " || die "未选择 Relay"
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )) || \
            die "选择无效"
        requested="${candidates[$((choice - 1))]%%$'\t'*}"
    fi

    line=""
    for candidate in "${candidates[@]}"; do
        [[ "${candidate%%$'\t'*}" == "$requested" ]] && { line="$candidate"; break; }
    done
    [[ -n "$line" ]] || die "未找到可删除 Relay: $requested"
    IFS=$'\t' read -r name listen backend chain <<< "$line"

    prompt_read confirm "确认删除 ${name}（$listen -> ${backend}）并重启 ${CN_RELAY_UNIT}？[y/N]: " || \
        die "操作已取消"
    case "$confirm" in y|Y|yes|YES) ;; *) echo "已取消。"; return 0 ;; esac

    candidate="$(mktemp "$CN_RELAY_DIR/.cn.yaml.relay.XXXXXX")"
    if ! awk -v target="$name" '
        $0 == "# standalone-relay: " target { next }
        /^- name:[[:space:]]*/ {
            current = $0
            sub(/^- name:[[:space:]]*/, "", current)
            sub(/[[:space:]]+$/, "", current)
            if (current == target) {
                skipping = 1
                found = 1
                next
            }
            skipping = 0
        }
        /^chains:[[:space:]]*$/ { skipping = 0 }
        !skipping { print }
        END { if (!found) exit 42 }
    ' "$CN_RELAY_YAML" > "$candidate"; then
        rm -f "$candidate"
        die "删除失败，cn.yaml 未修改"
    fi
    apply_cn_relay_yaml "$candidate" "已删除 ${name}（$listen -> ${backend}）"
}

manage_cn_relays() {
    local action="${1:-}" target="${2:-}" choice
    check_command awk
    check_command "$SYSTEMCTL_BIN"
    resolve_cn_relay_context

    case "$action" in
        list) list_cn_relays ;;
        add) add_cn_relay ;;
        remove|delete|rm) remove_cn_relay "$target" ;;
        "")
            while :; do
                list_cn_relays
                cat <<'RELAY_MENU'
  1) 增加 Relay
  2) 删除 Relay
  3) 刷新列表
  q) 返回
RELAY_MENU
                prompt_read choice "请选择 [1/2/3/q]: " || return 0
                case "$choice" in
                    1) add_cn_relay ;;
                    2) remove_cn_relay ;;
                    3) ;;
                    q|Q|quit|exit) return 0 ;;
                    *) echo "无效选择" >&2 ;;
                esac
            done
            ;;
        *) die "未知 Relay 操作: ${action}（支持 list/add/remove）" ;;
    esac
}

main() {
    local SELECTED_ROLE="" RELAY_ACTION="" RELAY_TARGET=""

    prepare_embedded_source

    case "${1:-}" in
        --help|-h)
            show_usage
            exit 0
            ;;
        --version|-v)
            echo "9929-gost-mtcp standalone installer v${VERSION}"
            exit 0
            ;;
        cn|remote)
            SELECTED_ROLE="$1"
            ;;
        relay)
            SELECTED_ROLE="relay"
            RELAY_ACTION="${2:-}"
            RELAY_TARGET="${3:-}"
            ;;
        "")
            show_banner
            select_role_interactively
            ;;
        *)
            echo "错误: 无效参数 '$1'" >&2
            show_usage
            exit 1
            ;;
    esac

    check_root

    case "$SELECTED_ROLE" in
        remote) install_remote ;;
        cn) install_cn ;;
        relay) manage_cn_relays "$RELAY_ACTION" "$RELAY_TARGET" ;;
    esac
}

main "$@"
exit $?

# ============================================================
# 以下内容由 scripts/generate-standalone.sh 从 cn/ 与 remote/ 生成。
# ============================================================
# === GENERATED EMBEDDED FILES: DO NOT EDIT ===

### BEGIN REMOTE_YAML ###
services:
- name: mtcp-server
  addr: :6600
  handler:
    type: relay
  listener:
    type: mtcp
    metadata:
      mux.version: 2
      mux.keepaliveDisabled: false
      mux.keepaliveInterval: 10s
      mux.keepaliveTimeout: 30s
      mux.maxFrameSize: 32768
      mux.maxReceiveBuffer: 33554432
      mux.maxStreamBuffer: 4194304

### END REMOTE_YAML ###

### BEGIN REMOTE_MAIN_SERVICE ###
[Unit]
Description=9929 GOST MTCP v1 Remote Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=/root/9929-gost-mtcp/remote
ExecStartPre=/usr/bin/test -x /root/9929-gost-mtcp/remote/gost
ExecStartPre=/usr/bin/test -r /root/9929-gost-mtcp/remote/remote.yaml
ExecStart=/root/9929-gost-mtcp/remote/gost -D -C /root/9929-gost-mtcp/remote/remote.yaml
Restart=always
RestartSec=2
TimeoutStopSec=15
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target

### END REMOTE_MAIN_SERVICE ###

### BEGIN REMOTE_ANCHOR_SERVICE ###
[Unit]
Description=9929 GOST MTCP v1 Remote Anchor Endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat -d -d TCP-LISTEN:12346,bind=127.0.0.1,reuseaddr,fork EXEC:/bin/cat
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target

### END REMOTE_ANCHOR_SERVICE ###

### BEGIN CN_YAML ###
services:
- name: tcp-entry
  addr: :12000
  handler:
    type: tcp
    chain: chain-mtcp
  listener:
    type: tcp
  forwarder:
    nodes:
    - name: backend
      addr: 127.0.0.1:2345

# 专用 MTCP 锚定入口，仅监听本机。
# Anchor 会主动发送 1 Byte 触发默认 Relay 首包逻辑，因此共享 connector 保持原始默认行为。
- name: mtcp-anchor
  addr: 127.0.0.1:12001
  handler:
    type: tcp
    chain: chain-mtcp
  listener:
    type: tcp
  forwarder:
    nodes:
    - name: anchor
      addr: 127.0.0.1:12346

chains:
- name: chain-mtcp
  hops:
  - name: remote
    nodes:
    - name: remote-mtcp
      addr: remote.example.invalid:6600
      connector:
        type: relay
      dialer:
        type: mtcp
        metadata:
          mux.version: 2
          mux.keepaliveDisabled: false
          mux.keepaliveInterval: 10s
          mux.keepaliveTimeout: 30s
          mux.maxFrameSize: 32768
          mux.maxReceiveBuffer: 33554432
          mux.maxStreamBuffer: 4194304

### END CN_YAML ###

### BEGIN CN_MTCP_CONF ###
# GOST MTCP Remote v1 configuration
# watchdog 每轮重新 source，本文件中的阈值修改后无需重启 watchdog。

# ---- systemd / path ----
UNIT="9929-gost-mtcp.service"
ANCHOR_UNIT="9929-gost-mtcp-anchor.service"
DST="remote.example.invalid"
PORT="6600"
BUSINESS_PORT="12000"
# 以空格或逗号分隔。BUSINESS_PORT 是主入口，必须包含在本列表中。
BUSINESS_PORTS="12000"
ANCHOR_HOST="127.0.0.1"
ANCHOR_PORT="12001"

# ---- ECMP 新 session 准入 ----
ACCEPT_RTT_MS="40"

# ---- 运行中 RTT 监控：只告警，不因当前 RTT 高主动 kill ----
LIVE_RTT_WARN_MS="120"
LIVE_RTT_CRIT_MS="250"
LIVE_RTT_WARN_HOLD_SEC="30"
LIVE_RTT_CRIT_HOLD_SEC="120"
LIVE_RTT_RECOVER_MS="80"
LIVE_RTT_RECOVER_HOLD_SEC="30"

# ---- prewarm / 抽卡 ----
PREWARM_MAX_DRAWS="12"
RECOVERY_PREWARM_DRAWS="8"
DEGRADED_RETRY_DRAWS="4"
PREWARM_NO_SESSION_ATTEMPTS="5"
PREWARM_CONNECT_WAIT_SEC="2"
PREWARM_STABLE_REQUIRED="2"
PREWARM_STABLE_INTERVAL_SEC="1"
PREWARM_KILL_WAIT_SEC="2"
PREWARM_TOTAL_TIMEOUT_SEC="120"

# ---- Anchor ----
# Anchor 本身就是候选 session 的建立者和最终锚定者：
# start Anchor -> 主动发 1 Byte -> 建立 outer -> 检测 minrtt -> 慢则 stop+kill -> 重抽；快则直接留下。
ANCHOR_START_TIMEOUT_SEC="8"
ANCHOR_STABLE_REQUIRED="2"
ANCHOR_STABLE_INTERVAL_SEC="1"
ANCHOR_RETRY_SEC="60"

# ---- DEGRADED(PATH) 自动恢复 ----
DEGRADED_RETRY_SEC="900"
DEGRADED_BUSY_DEFER_SEC="60"
BUSINESS_IDLE_HOLD_SEC="15"

# ---- watchdog / recovery ----
WATCH_INTERVAL_SEC="5"
ZERO_GRACE_SEC="5"
REMOTE_PROBE_INTERVAL_SEC="15"
REMOTE_PROBE_TIMEOUT_SEC="2"
REMOTE_PROBE_ATTEMPTS="2"
# 通过本地 Anchor 入口发送并收回 1 Byte，验证当前 MTCP outer 的真实双向数据面。
DATA_PROBE_ENABLED="yes"
DATA_PROBE_INTERVAL_SEC="15"
DATA_PROBE_TIMEOUT_SEC="3"
DATA_PROBE_FAIL_THRESHOLD="3"
# 10 分钟内最多允许 3 次 stale-outer 重启；达到上限后熔断 10 分钟。
DATA_PROBE_RESTART_WINDOW_SEC="600"
DATA_PROBE_RESTART_MAX="3"
DATA_PROBE_BREAKER_OPEN_SEC="600"
DOWN_RETRY_SEC="15"
STUCK_RESTART_AFTER_SEC="60"
RESTART_COOLDOWN_SEC="60"
MULTI_CONFIRM_COUNT="2"
# GOST 因 systemd StartLimit 等原因停止时，低频尝试 reset-failed + restart。
PROCESS_RECOVERY_GRACE_SEC="10"
PROCESS_RECOVERY_INTERVAL_SEC="60"
PROCESS_RECOVERY_WINDOW_SEC="600"
PROCESS_RECOVERY_MAX="3"
PROCESS_BREAKER_OPEN_SEC="600"

# ---- state / retention ----
STATE_DIR="/root/9929-gost-mtcp/cn/state"
STATE_FILE="/root/9929-gost-mtcp/cn/state/runtime.state"
STATUS_JSON="/root/9929-gost-mtcp/cn/state/status.json"
EVENT_FILE="/root/9929-gost-mtcp/cn/state/events.jsonl"
RETENTION_SEC="86400"

### END CN_MTCP_CONF ###

### BEGIN CN_MAIN_SERVICE ###
[Unit]
Description=9929 GOST MTCP v1 Data Plane
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=/root/9929-gost-mtcp/cn
ExecStartPre=/usr/bin/test -x /root/9929-gost-mtcp/cn/gost
ExecStartPre=/usr/bin/test -r /root/9929-gost-mtcp/cn/cn.yaml
ExecStart=/root/9929-gost-mtcp/cn/gost -D -C /root/9929-gost-mtcp/cn/cn.yaml
Restart=always
RestartSec=2
TimeoutStopSec=15
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target

### END CN_MAIN_SERVICE ###

### BEGIN CN_ANCHOR_SERVICE ###
[Unit]
Description=9929 GOST MTCP v1 Anchor Stream
After=9929-gost-mtcp.service
Requires=9929-gost-mtcp.service
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=/
# 默认 Relay 不改 nodelay。Anchor 主动发送 1 Byte，随后持续读取，长期占住一个 logical stream。
ExecStart=/bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/12001; printf "A" >&3; exec cat <&3 >/dev/null'
Restart=always
RestartSec=5
TimeoutStopSec=5
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal

# 故意没有 [Install]：不要 enable。
# 只允许 prewarm/watchdog 控制，以免开机时抢先锚定未经优选的 outer。

### END CN_ANCHOR_SERVICE ###

### BEGIN CN_WATCHDOG_SERVICE ###
[Unit]
Description=9929 GOST MTCP v1 Watchdog
After=network-online.target 9929-gost-mtcp.service
Wants=network-online.target 9929-gost-mtcp.service
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
WorkingDirectory=/root/9929-gost-mtcp/cn
Environment="MTCP_LIB=/root/9929-gost-mtcp/cn/mtcp-lib.sh"
Environment="MTCP_PREWARM=/root/9929-gost-mtcp/cn/mtcp-prewarm.sh"
ExecStartPre=/usr/bin/test -r /root/9929-gost-mtcp/cn/mtcp.conf
ExecStartPre=/usr/bin/test -x /root/9929-gost-mtcp/cn/mtcp-watchdog.sh
ExecStart=/root/9929-gost-mtcp/cn/mtcp-watchdog.sh /root/9929-gost-mtcp/cn/mtcp.conf
Restart=always
RestartSec=2
TimeoutStopSec=10
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target

### END CN_WATCHDOG_SERVICE ###

### BEGIN CN_LIB ###
#!/usr/bin/env bash
set -uo pipefail

CONFIG_DEFAULT="/root/9929-gost-mtcp/cn/mtcp.conf"
CONFIG_KEYS=(
    UNIT ANCHOR_UNIT DST PORT BUSINESS_PORT BUSINESS_PORTS ANCHOR_HOST ANCHOR_PORT
    ACCEPT_RTT_MS
    LIVE_RTT_WARN_MS LIVE_RTT_CRIT_MS LIVE_RTT_WARN_HOLD_SEC
    LIVE_RTT_CRIT_HOLD_SEC LIVE_RTT_RECOVER_MS LIVE_RTT_RECOVER_HOLD_SEC
    PREWARM_MAX_DRAWS RECOVERY_PREWARM_DRAWS DEGRADED_RETRY_DRAWS
    PREWARM_NO_SESSION_ATTEMPTS PREWARM_CONNECT_WAIT_SEC PREWARM_STABLE_REQUIRED
    PREWARM_STABLE_INTERVAL_SEC PREWARM_KILL_WAIT_SEC PREWARM_TOTAL_TIMEOUT_SEC
    ANCHOR_START_TIMEOUT_SEC ANCHOR_STABLE_REQUIRED ANCHOR_STABLE_INTERVAL_SEC
    ANCHOR_RETRY_SEC DEGRADED_RETRY_SEC DEGRADED_BUSY_DEFER_SEC BUSINESS_IDLE_HOLD_SEC
    WATCH_INTERVAL_SEC ZERO_GRACE_SEC REMOTE_PROBE_INTERVAL_SEC
    REMOTE_PROBE_TIMEOUT_SEC REMOTE_PROBE_ATTEMPTS DOWN_RETRY_SEC
    DATA_PROBE_ENABLED DATA_PROBE_INTERVAL_SEC DATA_PROBE_TIMEOUT_SEC
    DATA_PROBE_FAIL_THRESHOLD DATA_PROBE_RESTART_WINDOW_SEC DATA_PROBE_RESTART_MAX
    DATA_PROBE_BREAKER_OPEN_SEC
    STUCK_RESTART_AFTER_SEC RESTART_COOLDOWN_SEC MULTI_CONFIRM_COUNT
    PROCESS_RECOVERY_GRACE_SEC PROCESS_RECOVERY_INTERVAL_SEC PROCESS_RECOVERY_WINDOW_SEC PROCESS_RECOVERY_MAX
    PROCESS_BREAKER_OPEN_SEC
    STATE_DIR STATE_FILE STATUS_JSON EVENT_FILE RETENTION_SEC
)

load_config() {
    local cfg="${1:-$CONFIG_DEFAULT}"
    [[ -r "$cfg" ]] || { echo "config not readable: $cfg" >&2; return 1; }

    # watchdog 会重复加载配置；先清空已知键，避免删除配置项后继续沿用旧值。
    unset "${CONFIG_KEYS[@]}"
    # shellcheck disable=SC1090
    source "$cfg" || { echo "config invalid: $cfg" >&2; return 1; }

    local required
    for required in UNIT ANCHOR_UNIT DST PORT BUSINESS_PORT ANCHOR_HOST ANCHOR_PORT ACCEPT_RTT_MS; do
        if [[ -z "${!required:-}" ]]; then
            echo "$required missing in config: $cfg" >&2
            return 1
        fi
    done

    STATE_DIR="${STATE_DIR:-/root/9929-gost-mtcp/cn/state}"
    STATE_FILE="${STATE_FILE:-${STATE_DIR}/runtime.state}"
    STATUS_JSON="${STATUS_JSON:-${STATE_DIR}/status.json}"
    EVENT_FILE="${EVENT_FILE:-${STATE_DIR}/events.jsonl}"
    RETENTION_SEC="${RETENTION_SEC:-86400}"

    BUSINESS_PORTS="${BUSINESS_PORTS:-$BUSINESS_PORT}"
    BUSINESS_PORTS="${BUSINESS_PORTS//,/ }"
    local port seen=" " normalized="" found_primary=no
    for port in $BUSINESS_PORTS; do
        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            echo "invalid port in BUSINESS_PORTS: $port" >&2
            return 1
        fi
        [[ "$port" == "$ANCHOR_PORT" ]] && {
            echo "BUSINESS_PORTS must not contain ANCHOR_PORT: $port" >&2
            return 1
        }
        [[ "$port" == "$BUSINESS_PORT" ]] && found_primary=yes
        if [[ "$seen" != *" $port "* ]]; then
            normalized="${normalized:+$normalized }$port"
            seen+="$port "
        fi
    done
    [[ -n "$normalized" && "$found_primary" == yes ]] || {
        echo "BUSINESS_PORTS must include BUSINESS_PORT ($BUSINESS_PORT)" >&2
        return 1
    }
    BUSINESS_PORTS="$normalized"

    DATA_PROBE_ENABLED="${DATA_PROBE_ENABLED:-yes}"
    DATA_PROBE_INTERVAL_SEC="${DATA_PROBE_INTERVAL_SEC:-15}"
    DATA_PROBE_TIMEOUT_SEC="${DATA_PROBE_TIMEOUT_SEC:-3}"
    DATA_PROBE_FAIL_THRESHOLD="${DATA_PROBE_FAIL_THRESHOLD:-3}"
    DATA_PROBE_RESTART_WINDOW_SEC="${DATA_PROBE_RESTART_WINDOW_SEC:-600}"
    DATA_PROBE_RESTART_MAX="${DATA_PROBE_RESTART_MAX:-3}"
    DATA_PROBE_BREAKER_OPEN_SEC="${DATA_PROBE_BREAKER_OPEN_SEC:-600}"
    BUSINESS_IDLE_HOLD_SEC="${BUSINESS_IDLE_HOLD_SEC:-15}"
    PROCESS_RECOVERY_GRACE_SEC="${PROCESS_RECOVERY_GRACE_SEC:-10}"
    PROCESS_RECOVERY_INTERVAL_SEC="${PROCESS_RECOVERY_INTERVAL_SEC:-60}"
    PROCESS_RECOVERY_WINDOW_SEC="${PROCESS_RECOVERY_WINDOW_SEC:-600}"
    PROCESS_RECOVERY_MAX="${PROCESS_RECOVERY_MAX:-3}"
    PROCESS_BREAKER_OPEN_SEC="${PROCESS_BREAKER_OPEN_SEC:-600}"
    case "$DATA_PROBE_ENABLED" in
      yes|no) ;;
      *) echo "DATA_PROBE_ENABLED must be yes or no in config: $cfg" >&2; return 1 ;;
    esac
    local probe_key
    for probe_key in DATA_PROBE_INTERVAL_SEC DATA_PROBE_TIMEOUT_SEC DATA_PROBE_FAIL_THRESHOLD \
      DATA_PROBE_RESTART_WINDOW_SEC DATA_PROBE_RESTART_MAX DATA_PROBE_BREAKER_OPEN_SEC \
      BUSINESS_IDLE_HOLD_SEC PROCESS_RECOVERY_GRACE_SEC PROCESS_RECOVERY_INTERVAL_SEC PROCESS_RECOVERY_WINDOW_SEC \
      PROCESS_RECOVERY_MAX PROCESS_BREAKER_OPEN_SEC; do
        if [[ ! "${!probe_key}" =~ ^[1-9][0-9]*$ ]]; then
            echo "$probe_key must be a positive integer in config: $cfg" >&2
            return 1
        fi
    done
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
# UNIT 由 load_config 从实例配置加载。
# shellcheck disable=SC2153
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
    # 单次抓取避免逐端口查询之间的时间差；只统计当前 GOST PID 的本地业务入口。
    ss -ntpH state established 2>/dev/null |
      awk -v needle="pid=${pid}," -v ports="$BUSINESS_PORTS" '
        BEGIN { nports=split(ports,p,/ +/); for (i=1;i<=nports;i++) wanted[p[i]]=1 }
        index($0,needle) {
          ep=$4; sub(/^.*:/,"",ep)
          if (wanted[ep]) n++
        }
        END { print n+0 }
      '
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

# 经本地 Anchor 入口建立一个新的 logical stream，并验证 payload 能沿当前
# chain-mtcp -> outer -> Remote echo endpoint 完成一次双向传输。
data_plane_probe() {
    local host="${ANCHOR_HOST:-127.0.0.1}"
    local port="${ANCHOR_PORT:-12001}"
    local timeout_sec="${DATA_PROBE_TIMEOUT_SEC:-3}"

    timeout "$timeout_sec" bash -c '
        exec 3<>"/dev/tcp/${1}/${2}" || exit 1
        printf "P" >&3 || exit 1
        reply=""
        IFS= read -r -n 1 reply <&3 || exit 1
        [[ "$reply" == "P" ]]
    ' _ "$host" "$port" >/dev/null 2>&1
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
    local data_plane="${9:-unknown}" data_failures="${10:-0}"
    local apid acount business astate tmp epoch ts
    local data_breaker process_breaker
    [[ "$data_failures" =~ ^[0-9]+$ ]] || data_failures=0
    apid="$(get_anchor_pid)"; acount="$(get_anchor_conn_count "$apid")"
    business="$(get_business_conn_count "$pid")"
    data_breaker="${DATA_PROBE_BREAKER_STATE:-closed}"
    process_breaker="${PROCESS_BREAKER_STATE:-closed}"
    if (( apid > 0 && acount == 1 )); then astate="up"; elif (( apid > 0 )); then astate="starting"; else astate="down"; fi
    epoch="$(now_epoch)"; ts="$(now_text)"; tmp="${STATUS_JSON}.tmp.$$"
    printf '{"epoch":%s,"ts":"%s","state":"%s","reason":"%s","unit":"%s","dst":"%s","port":%s,"business_ports":"%s","pid":%s,"outer_count":%s,"sport":"%s","minrtt_ms":"%s","rtt_ms":"%s","remote_reachable":"%s","data_plane_reachable":"%s","data_probe_failures":%s,"data_probe_breaker":"%s","process_breaker":"%s","anchor_unit":"%s","anchor_state":"%s","anchor_pid":%s,"anchor_connections":%s,"business_connections":%s}\n' \
      "$epoch" "$(json_escape "$ts")" "$(json_escape "$state")" "$(json_escape "$reason")" "$(json_escape "$UNIT")" \
      "$(json_escape "$DST")" "$PORT" "$(json_escape "$BUSINESS_PORTS")" "${pid:-0}" "${outer:-0}" "$(json_escape "$sport")" "$(json_escape "$minrtt")" "$(json_escape "$rtt")" \
      "$(json_escape "$remote")" "$(json_escape "$data_plane")" "$data_failures" "$(json_escape "$data_breaker")" \
      "$(json_escape "$process_breaker")" "$(json_escape "$ANCHOR_UNIT")" "$astate" \
      "${apid:-0}" "${acount:-0}" "${business:-0}" > "$tmp"
    mv -f "$tmp" "$STATUS_JSON"
}

### END CN_LIB ###

### BEGIN CN_PREWARM ###
#!/usr/bin/env bash
set -uo pipefail

CONFIG="${1:-/root/9929-gost-mtcp/cn/mtcp.conf}"
LIB="${MTCP_LIB:-/root/9929-gost-mtcp/cn/mtcp-lib.sh}"
# shellcheck disable=SC1090
source "$LIB"
load_config "$CONFIG" || exit 30

MODE="${MTCP_PREWARM_MODE:-normal}"
case "$MODE" in
  degraded-retry) MAX_DRAWS="${DEGRADED_RETRY_DRAWS:-4}" ;;
  recovery)       MAX_DRAWS="${RECOVERY_PREWARM_DRAWS:-8}" ;;
  *)              MAX_DRAWS="${PREWARM_MAX_DRAWS:-12}" ;;
esac

LOCK_ID="${UNIT%.service}"
LOCK_ID="${LOCK_ID//[^A-Za-z0-9_.@-]/_}"
LOCK="/run/${LOCK_ID}-prewarm.lock"
exec {LOCKFD}>"$LOCK"
flock -n "$LOCKFD" || exit 75

abort_degraded_retry_if_busy() {
    local phase="$1" pid business count sport info minrtt rtt
    [[ "$MODE" == "degraded-retry" ]] || return 1
    pid="$(get_main_pid)"
    business="$(get_business_conn_count "$pid")"
    (( business > 0 )) || return 1

    # Watchdog 的 idle 判断与真正切路之间存在时间窗。这里是 destructive
    # action 前的最后一道闸：一旦业务出现，恢复/保持 Anchor 并保留当前 outer。
    ensure_anchor || true
    count="$(get_gost_outer_count "$pid")"
    sport="$(get_single_sport "$pid" 2>/dev/null || true)"
    info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
    write_status_json "DEGRADED" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "$count" "yes"
    log_event "DEGRADED" "PREWARM_ABORT_BUSY" "PATH" "$pid" "$sport" "$minrtt" "$rtt" \
        "mode=$MODE phase=$phase business=$business"
    exit 10
}

# v1：Anchor 本身负责建立候选 outer 并在成功后直接留下。
# 抽慢路时先 stop Anchor，再 kill 当前唯一 outer；避免自动重连竞争。
abort_degraded_retry_if_busy "before_initial_anchor_stop"
stop_anchor

start_epoch="$(now_epoch)"
attempt=0
no_session_attempts=0
stable=0
candidate_sport=""

while (( $(now_epoch) - start_epoch < ${PREWARM_TOTAL_TIMEOUT_SEC:-120} )); do
    pid="$(get_main_pid)"
    if (( pid <= 0 )) || ! service_is_active; then
        stop_anchor
        write_status_json "DOWN" "PROCESS" "$pid" "" "" "" 0 "unknown"
        log_event "DOWN" "PREWARM_PROCESS_DOWN" "PROCESS" "$pid"
        exit 20
    fi

    count="$(get_gost_outer_count "$pid")"
    if (( count > 1 )); then
        stop_anchor
        write_status_json "FAULT" "MULTI_OUTER" "$pid" "" "" "" "$count" "unknown"
        log_event "FAULT" "PREWARM_MULTI_OUTER" "MULTI_OUTER" "$pid" "" "" "" "count=$count"
        exit 30
    fi

    # 没有 outer：启动 Anchor。Anchor 会主动发送 1 Byte，触发默认 Relay 并保持 logical stream。
    if (( count == 0 )); then
        stable=0; candidate_sport=""
        if ! ensure_anchor; then
            stop_anchor
            ((no_session_attempts++))
            log_event "DOWN" "PREWARM_ANCHOR_START_RETRY" "ANCHOR" "$pid" "" "" "" "attempt=$no_session_attempts/${PREWARM_NO_SESSION_ATTEMPTS:-5}"
            if (( no_session_attempts >= ${PREWARM_NO_SESSION_ATTEMPTS:-5} )); then
                write_status_json "DOWN" "NO_OUTER" "$pid" "" "" "" 0 "unknown"
                log_event "DOWN" "PREWARM_NO_OUTER" "NO_OUTER" "$pid"
                exit 20
            fi
            sleep 1
            continue
        fi
        sleep "${PREWARM_CONNECT_WAIT_SEC:-2}"
        continue
    fi

    no_session_attempts=0
    sport="$(get_single_sport "$pid" 2>/dev/null || true)"
    [[ -n "$sport" ]] || { sleep 0.2; continue; }

    # 若 outer 已存在但 Anchor 尚未挂上，先挂 Anchor；这不会新建第二条 outer，成功后再确认。
    if ! anchor_is_established; then
        if ! ensure_anchor; then
            stop_anchor
            info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
            write_status_json "DEGRADED" "ANCHOR" "$pid" "$sport" "$minrtt" "$rtt" 1 "yes"
            log_event "DEGRADED" "PREWARM_ANCHOR_FAILED" "ANCHOR" "$pid" "$sport" "$minrtt" "$rtt"
            exit 11
        fi
        sleep "${ANCHOR_STABLE_INTERVAL_SEC:-1}"
        count="$(get_gost_outer_count "$pid")"
        (( count == 1 )) || continue
        sport="$(get_single_sport "$pid" 2>/dev/null || true)"
        [[ -n "$sport" ]] || continue
    fi

    if [[ "$candidate_sport" != "$sport" ]]; then
        candidate_sport="$sport"
        stable=0
        ((attempt++))
    fi

    info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
    [[ -n "$minrtt" ]] || { stable=0; sleep 0.3; continue; }

    if is_lt "$minrtt" "$ACCEPT_RTT_MS"; then
        ((stable++))
        write_status_json "FAST" "PATH" "$pid" "$sport" "$minrtt" "$rtt" 1 "yes"
        if (( stable >= ${PREWARM_STABLE_REQUIRED:-2} )); then
            # 成功时 Anchor 已经在线，因此没有“prewarm 成功后 outer 空窗期”。
            count="$(get_gost_outer_count "$pid")"
            current="$(get_single_sport "$pid" 2>/dev/null || true)"
            if (( count == 1 )) && [[ "$current" == "$sport" ]] && anchor_is_established; then
                log_event "FAST" "PREWARM_SUCCESS" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "mode=$MODE attempt=$attempt/$MAX_DRAWS"
                exit 0
            fi
            stable=0
            continue
        fi
        sleep "${PREWARM_STABLE_INTERVAL_SEC:-1}"
        continue
    fi

    stable=0
    if (( attempt >= MAX_DRAWS )); then
        # 抽卡额度耗尽：保留最后一条可用慢路，并保持 Anchor，业务优先。
        write_status_json "DEGRADED" "PATH" "$pid" "$sport" "$minrtt" "$rtt" 1 "yes"
        log_event "DEGRADED" "PREWARM_KEEP_SLOW" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "mode=$MODE attempt=$attempt/$MAX_DRAWS"
        exit 10
    fi

    log_event "DEGRADED" "PREWARM_REJECT_SLOW" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "mode=$MODE attempt=$attempt/$MAX_DRAWS"

    # 先停 Anchor；如果 outer 因最后一个 logical stream 消失而自己释放，就无需再 ss -K。
    abort_degraded_retry_if_busy "before_anchor_stop"
    stop_anchor
    sleep 0.1

    pid2="$(get_main_pid)"
    [[ "$pid2" == "$pid" ]] || exit 30
    count2="$(get_gost_outer_count "$pid")"
    if (( count2 == 0 )); then
        candidate_sport=""; stable=0
        continue
    fi
    if (( count2 > 1 )); then
        write_status_json "FAULT" "MULTI_OUTER" "$pid" "" "" "" "$count2" "unknown"
        log_event "FAULT" "PREWARM_MULTI_AFTER_ANCHOR_STOP" "MULTI_OUTER" "$pid" "" "" "" "count=$count2"
        exit 30
    fi

    sport2="$(get_single_sport "$pid" 2>/dev/null || true)"
    if [[ "$sport2" != "$sport" ]]; then
        # session 已自行换代；把新 sport 当下一张卡，不猜不杀。
        candidate_sport=""; stable=0
        continue
    fi

    abort_degraded_retry_if_busy "before_outer_kill"

    if ! kill_outer_sport "$pid" "$sport"; then
        # 再看一次：若恰好自然消失，按成功清理处理；否则才是故障。
        count3="$(get_gost_outer_count "$pid")"
        if (( count3 == 0 )); then candidate_sport=""; continue; fi
        write_status_json "FAULT" "KILL_FAILED" "$pid" "$sport" "$minrtt" "$rtt" "$count3" "unknown"
        log_event "FAULT" "PREWARM_KILL_FAILED" "KILL_FAILED" "$pid" "$sport" "$minrtt" "$rtt"
        exit 31
    fi

    if ! wait_outer_gone "$pid" "$sport" "${PREWARM_KILL_WAIT_SEC:-2}"; then
        write_status_json "FAULT" "KILL_TIMEOUT" "$pid" "$sport" "$minrtt" "$rtt" 1 "unknown"
        log_event "FAULT" "PREWARM_KILL_TIMEOUT" "KILL_TIMEOUT" "$pid" "$sport" "$minrtt" "$rtt"
        exit 31
    fi

    candidate_sport=""; stable=0
    # 下一轮由 Anchor 建立新的候选 outer。
done

pid="$(get_main_pid)"; count="$(get_gost_outer_count "$pid")"
if (( count == 1 )); then
    sport="$(get_single_sport "$pid" 2>/dev/null || true)"
    if ! anchor_is_established; then ensure_anchor || true; fi
    info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
    write_status_json "DEGRADED" "PREWARM_TIMEOUT" "$pid" "$sport" "$minrtt" "$rtt" 1 "unknown"
    log_event "DEGRADED" "PREWARM_TIMEOUT_KEEP_CURRENT" "PREWARM_TIMEOUT" "$pid" "$sport" "$minrtt" "$rtt" "attempt=$attempt/$MAX_DRAWS"
    exit 10
fi
stop_anchor
write_status_json "DOWN" "PREWARM_TIMEOUT" "$pid" "" "" "" "$count" "unknown"
log_event "DOWN" "PREWARM_TIMEOUT_NO_OUTER" "PREWARM_TIMEOUT" "$pid"
exit 20

### END CN_PREWARM ###

### BEGIN CN_WATCHDOG ###
#!/usr/bin/env bash
set -uo pipefail

DEFAULT_CONFIG="${MTCP_CONFIG:-/root/9929-gost-mtcp/cn/mtcp.conf}"
CONFIG="${1:-$DEFAULT_CONFIG}"
ADOPT_MODE=0
if [[ "${1:-}" == "--adopt" ]]; then
    CONFIG="$DEFAULT_CONFIG"
    ADOPT_MODE=1
elif [[ "${2:-}" == "--adopt" ]]; then
    ADOPT_MODE=1
fi

LIB="${MTCP_LIB:-/root/9929-gost-mtcp/cn/mtcp-lib.sh}"
PREWARM="${MTCP_PREWARM:-/root/9929-gost-mtcp/cn/mtcp-prewarm.sh}"
# shellcheck disable=SC1090
source "$LIB"
load_config "$CONFIG" || exit 1

LOCK_ID="${UNIT%.service}"
LOCK_ID="${LOCK_ID//[^A-Za-z0-9_.@-]/_}"
LOCK="/run/${LOCK_ID}-watchdog.lock"
exec {LOCKFD}>"$LOCK"
if ! flock -n "$LOCKFD"; then
    if (( ADOPT_MODE == 1 )); then
        echo "cannot adopt: watchdog lock is held for $UNIT" >&2
        exit 75
    fi
    exit 0
fi

BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"

reset_data_probe_state() {
    LAST_DATA_PROBE=0
    DATA_PROBE_FAILS=0
    DATA_PLANE_OK="unknown"
    DATA_PROBE_SPORT=""
}

reset_runtime_state() {
    SAVED_BOOT_ID=""
    STATE="INIT"; REASON=""; LAST_PID=0; LAST_NONZERO_PID=0; LAST_SPORT=""
    ZERO_SINCE=0; WARN_SINCE=0; CRIT_SINCE=0; RECOVER_SINCE=0
    LAST_REMOTE_PROBE=0; REMOTE_OK="unknown"; LAST_RESTART=0; MULTI_SEEN=0
    LAST_DEGRADED_RETRY=0; LAST_RECOVERY_ATTEMPT=0; LAST_ANCHOR_RETRY=0; LAST_PRUNE=0
    BUSINESS_IDLE_SINCE=0
    DATA_PROBE_RESTART_EPOCHS=""; DATA_PROBE_BREAKER_STATE="closed"
    DATA_PROBE_BREAKER_UNTIL=0; DATA_PROBE_BREAKER_LOGGED=0
    PROCESS_RECOVERY_EPOCHS=""; PROCESS_BREAKER_STATE="closed"
    PROCESS_BREAKER_UNTIL=0; PROCESS_BREAKER_LOGGED=0
    LAST_PROCESS_RECOVERY=0; PROCESS_HEALTHY_SINCE=0; PROCESS_DOWN_SINCE=0
    reset_data_probe_state
    HAVE_RUNTIME=0
}

reset_runtime_state

load_runtime_state() {
    local saved_boot_id
    [[ -r "$STATE_FILE" ]] || return 1

    # 先检查首行 boot ID，避免跨重启状态在校验前污染当前进程变量。
    saved_boot_id="$(awk -F"'" 'NR == 1 && $1 == "SAVED_BOOT_ID=" { print $2; exit }' "$STATE_FILE" 2>/dev/null || true)"
    [[ -n "$saved_boot_id" && "$saved_boot_id" == "$BOOT_ID" ]] || return 1

    # shellcheck disable=SC1090
    if ! source "$STATE_FILE"; then
        reset_runtime_state
        return 1
    fi
    if [[ "${SAVED_BOOT_ID:-}" != "$BOOT_ID" ]]; then
        reset_runtime_state
        return 1
    fi
    : "${LAST_DATA_PROBE:=0}"
    : "${DATA_PROBE_FAILS:=0}"
    : "${DATA_PLANE_OK:=unknown}"
    : "${DATA_PROBE_SPORT:=}"
    : "${BUSINESS_IDLE_SINCE:=0}"
    : "${DATA_PROBE_RESTART_EPOCHS:=}"
    : "${DATA_PROBE_BREAKER_STATE:=closed}"
    : "${DATA_PROBE_BREAKER_UNTIL:=0}"
    : "${DATA_PROBE_BREAKER_LOGGED:=0}"
    : "${PROCESS_RECOVERY_EPOCHS:=}"
    : "${PROCESS_BREAKER_STATE:=closed}"
    : "${PROCESS_BREAKER_UNTIL:=0}"
    : "${PROCESS_BREAKER_LOGGED:=0}"
    : "${LAST_PROCESS_RECOVERY:=0}"
    : "${PROCESS_HEALTHY_SINCE:=0}"
    : "${PROCESS_DOWN_SINCE:=0}"
    if [[ ! "$LAST_DATA_PROBE" =~ ^[0-9]+$ || ! "$DATA_PROBE_FAILS" =~ ^[0-9]+$ ]] ||
       [[ "$DATA_PLANE_OK" != "yes" && "$DATA_PLANE_OK" != "no" && "$DATA_PLANE_OK" != "unknown" ]] ||
       [[ -n "$DATA_PROBE_SPORT" && ! "$DATA_PROBE_SPORT" =~ ^[0-9]+$ ]]; then
        reset_data_probe_state
    fi
    if [[ ! "$BUSINESS_IDLE_SINCE" =~ ^[0-9]+$ || ! "$DATA_PROBE_BREAKER_UNTIL" =~ ^[0-9]+$ ||
          ! "$DATA_PROBE_BREAKER_LOGGED" =~ ^[01]$ || ! "$PROCESS_BREAKER_UNTIL" =~ ^[0-9]+$ ||
          ! "$PROCESS_BREAKER_LOGGED" =~ ^[01]$ || ! "$LAST_PROCESS_RECOVERY" =~ ^[0-9]+$ ||
          ! "$PROCESS_HEALTHY_SINCE" =~ ^[0-9]+$ || ! "$PROCESS_DOWN_SINCE" =~ ^[0-9]+$ ]] ||
       [[ "$DATA_PROBE_RESTART_EPOCHS" =~ [^0-9\ ] || "$PROCESS_RECOVERY_EPOCHS" =~ [^0-9\ ] ]] ||
       [[ "$DATA_PROBE_BREAKER_STATE" != "closed" && "$DATA_PROBE_BREAKER_STATE" != "open" ]] ||
       [[ "$PROCESS_BREAKER_STATE" != "closed" && "$PROCESS_BREAKER_STATE" != "open" ]]; then
        BUSINESS_IDLE_SINCE=0
        DATA_PROBE_RESTART_EPOCHS=""; DATA_PROBE_BREAKER_STATE="closed"
        DATA_PROBE_BREAKER_UNTIL=0; DATA_PROBE_BREAKER_LOGGED=0
        PROCESS_RECOVERY_EPOCHS=""; PROCESS_BREAKER_STATE="closed"
        PROCESS_BREAKER_UNTIL=0; PROCESS_BREAKER_LOGGED=0
        LAST_PROCESS_RECOVERY=0; PROCESS_HEALTHY_SINCE=0; PROCESS_DOWN_SINCE=0
    fi
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
BUSINESS_IDLE_SINCE='$BUSINESS_IDLE_SINCE'
LAST_DATA_PROBE='$LAST_DATA_PROBE'
DATA_PROBE_FAILS='$DATA_PROBE_FAILS'
DATA_PLANE_OK='$DATA_PLANE_OK'
DATA_PROBE_SPORT='$DATA_PROBE_SPORT'
DATA_PROBE_RESTART_EPOCHS='$DATA_PROBE_RESTART_EPOCHS'
DATA_PROBE_BREAKER_STATE='$DATA_PROBE_BREAKER_STATE'
DATA_PROBE_BREAKER_UNTIL='$DATA_PROBE_BREAKER_UNTIL'
DATA_PROBE_BREAKER_LOGGED='$DATA_PROBE_BREAKER_LOGGED'
PROCESS_RECOVERY_EPOCHS='$PROCESS_RECOVERY_EPOCHS'
PROCESS_BREAKER_STATE='$PROCESS_BREAKER_STATE'
PROCESS_BREAKER_UNTIL='$PROCESS_BREAKER_UNTIL'
PROCESS_BREAKER_LOGGED='$PROCESS_BREAKER_LOGGED'
LAST_PROCESS_RECOVERY='$LAST_PROCESS_RECOVERY'
PROCESS_HEALTHY_SINCE='$PROCESS_HEALTHY_SINCE'
PROCESS_DOWN_SINCE='$PROCESS_DOWN_SINCE'
STATEEOF
    mv -f "$tmp" "$STATE_FILE"
}

prune_epoch_list() {
    local epochs="$1" cutoff="$2" epoch kept=""
    for epoch in $epochs; do
        (( epoch >= cutoff )) && kept="${kept:+$kept }$epoch"
    done
    printf '%s\n' "$kept"
}

close_data_probe_breaker() {
    if [[ "$DATA_PROBE_BREAKER_STATE" != "closed" || -n "$DATA_PROBE_RESTART_EPOCHS" ]]; then
        log_event "$STATE" "DATA_PROBE_BREAKER_CLOSED" "DATA_PLANE" "$LAST_PID" "$LAST_SPORT"
    fi
    DATA_PROBE_RESTART_EPOCHS=""; DATA_PROBE_BREAKER_STATE="closed"
    DATA_PROBE_BREAKER_UNTIL=0; DATA_PROBE_BREAKER_LOGGED=0
}

allow_data_probe_restart() {
    local now="$1" cutoff count half_open=0
    if [[ "$DATA_PROBE_BREAKER_STATE" == "open" ]]; then
        if (( now < DATA_PROBE_BREAKER_UNTIL )); then
            if (( DATA_PROBE_BREAKER_LOGGED == 0 )); then
                log_event "FAULT" "DATA_PROBE_BREAKER_SUPPRESSED" "DATA_PROBE" "$LAST_PID" "$LAST_SPORT" "" "" \
                    "until=$DATA_PROBE_BREAKER_UNTIL"
                DATA_PROBE_BREAKER_LOGGED=1
            fi
            return 1
        fi
        # 熔断时间到期只放行一次试探；若数据面仍坏，下一轮仍会被抑制。
        DATA_PROBE_RESTART_EPOCHS=""
        DATA_PROBE_BREAKER_STATE="closed"; DATA_PROBE_BREAKER_UNTIL=0; DATA_PROBE_BREAKER_LOGGED=0
        half_open=1
        log_event "FAULT" "DATA_PROBE_BREAKER_HALF_OPEN" "DATA_PROBE" "$LAST_PID" "$LAST_SPORT"
    fi

    cutoff=$((now - DATA_PROBE_RESTART_WINDOW_SEC))
    DATA_PROBE_RESTART_EPOCHS="$(prune_epoch_list "$DATA_PROBE_RESTART_EPOCHS" "$cutoff")"
    count=0; [[ -n "$DATA_PROBE_RESTART_EPOCHS" ]] && count="$(wc -w <<< "$DATA_PROBE_RESTART_EPOCHS" | tr -d ' ')"
    if (( count >= DATA_PROBE_RESTART_MAX )); then
        DATA_PROBE_BREAKER_STATE="open"; DATA_PROBE_BREAKER_UNTIL=$((now + DATA_PROBE_BREAKER_OPEN_SEC))
        DATA_PROBE_BREAKER_LOGGED=0
        log_event "FAULT" "DATA_PROBE_BREAKER_OPEN" "DATA_PROBE" "$LAST_PID" "$LAST_SPORT" "" "" \
            "attempts=$count window=${DATA_PROBE_RESTART_WINDOW_SEC}s until=$DATA_PROBE_BREAKER_UNTIL"
        return 1
    fi

    DATA_PROBE_RESTART_EPOCHS="${DATA_PROBE_RESTART_EPOCHS:+$DATA_PROBE_RESTART_EPOCHS }$now"
    count=$((count + 1))
    if (( half_open == 1 )); then
        DATA_PROBE_BREAKER_STATE="open"; DATA_PROBE_BREAKER_UNTIL=$((now + DATA_PROBE_BREAKER_OPEN_SEC))
        DATA_PROBE_BREAKER_LOGGED=0
        log_event "FAULT" "DATA_PROBE_BREAKER_REARMED" "DATA_PROBE" "$LAST_PID" "$LAST_SPORT" "" "" \
            "half_open_attempt=yes until=$DATA_PROBE_BREAKER_UNTIL"
    elif (( count >= DATA_PROBE_RESTART_MAX )); then
        DATA_PROBE_BREAKER_STATE="open"; DATA_PROBE_BREAKER_UNTIL=$((now + DATA_PROBE_BREAKER_OPEN_SEC))
        DATA_PROBE_BREAKER_LOGGED=0
        log_event "FAULT" "DATA_PROBE_BREAKER_ARMED" "DATA_PROBE" "$LAST_PID" "$LAST_SPORT" "" "" \
            "attempts=$count window=${DATA_PROBE_RESTART_WINDOW_SEC}s until=$DATA_PROBE_BREAKER_UNTIL"
    fi
    return 0
}

close_process_breaker() {
    if [[ "$PROCESS_BREAKER_STATE" != "closed" || -n "$PROCESS_RECOVERY_EPOCHS" ]]; then
        log_event "$STATE" "PROCESS_BREAKER_CLOSED" "PROCESS" "$LAST_PID" "$LAST_SPORT"
    fi
    PROCESS_RECOVERY_EPOCHS=""; PROCESS_BREAKER_STATE="closed"
    PROCESS_BREAKER_UNTIL=0; PROCESS_BREAKER_LOGGED=0; LAST_PROCESS_RECOVERY=0
}

allow_process_recovery() {
    local now="$1" cutoff count half_open=0
    if (( LAST_PROCESS_RECOVERY > 0 && now - LAST_PROCESS_RECOVERY < PROCESS_RECOVERY_INTERVAL_SEC )); then
        return 1
    fi
    if [[ "$PROCESS_BREAKER_STATE" == "open" ]]; then
        if (( now < PROCESS_BREAKER_UNTIL )); then
            if (( PROCESS_BREAKER_LOGGED == 0 )); then
                log_event "FAULT" "PROCESS_BREAKER_SUPPRESSED" "PROCESS" 0 "" "" "" "until=$PROCESS_BREAKER_UNTIL"
                PROCESS_BREAKER_LOGGED=1
            fi
            return 1
        fi
        PROCESS_RECOVERY_EPOCHS=""
        PROCESS_BREAKER_STATE="closed"; PROCESS_BREAKER_UNTIL=0; PROCESS_BREAKER_LOGGED=0
        half_open=1
        log_event "FAULT" "PROCESS_BREAKER_HALF_OPEN" "PROCESS" 0
    fi
    cutoff=$((now - PROCESS_RECOVERY_WINDOW_SEC))
    PROCESS_RECOVERY_EPOCHS="$(prune_epoch_list "$PROCESS_RECOVERY_EPOCHS" "$cutoff")"
    count=0; [[ -n "$PROCESS_RECOVERY_EPOCHS" ]] && count="$(wc -w <<< "$PROCESS_RECOVERY_EPOCHS" | tr -d ' ')"
    if (( count >= PROCESS_RECOVERY_MAX )); then
        PROCESS_BREAKER_STATE="open"; PROCESS_BREAKER_UNTIL=$((now + PROCESS_BREAKER_OPEN_SEC))
        PROCESS_BREAKER_LOGGED=0
        log_event "FAULT" "PROCESS_BREAKER_OPEN" "PROCESS" 0 "" "" "" \
            "attempts=$count window=${PROCESS_RECOVERY_WINDOW_SEC}s until=$PROCESS_BREAKER_UNTIL"
        return 1
    fi
    LAST_PROCESS_RECOVERY="$now"
    PROCESS_RECOVERY_EPOCHS="${PROCESS_RECOVERY_EPOCHS:+$PROCESS_RECOVERY_EPOCHS }$now"
    count=$((count + 1))
    if (( half_open == 1 )); then
        PROCESS_BREAKER_STATE="open"; PROCESS_BREAKER_UNTIL=$((now + PROCESS_BREAKER_OPEN_SEC))
        PROCESS_BREAKER_LOGGED=0
        log_event "FAULT" "PROCESS_BREAKER_REARMED" "PROCESS" 0 "" "" "" \
            "half_open_attempt=yes until=$PROCESS_BREAKER_UNTIL"
    elif (( count >= PROCESS_RECOVERY_MAX )); then
        PROCESS_BREAKER_STATE="open"; PROCESS_BREAKER_UNTIL=$((now + PROCESS_BREAKER_OPEN_SEC))
        PROCESS_BREAKER_LOGGED=0
        log_event "FAULT" "PROCESS_BREAKER_ARMED" "PROCESS" 0 "" "" "" \
            "attempts=$count window=${PROCESS_RECOVERY_WINDOW_SEC}s until=$PROCESS_BREAKER_UNTIL"
    fi
    return 0
}

recover_process_rate_limited() {
    local now="$1"
    allow_process_recovery "$now" || return 1
    log_event "DOWN" "PROCESS_RECOVERY_ATTEMPT" "PROCESS" 0 "" "" "" \
        "attempts=$(wc -w <<< "$PROCESS_RECOVERY_EPOCHS" | tr -d ' ')"
    systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
    if ! systemctl restart "$UNIT"; then
        log_event "FAULT" "PROCESS_RECOVERY_FAILED" "PROCESS" 0
        return 2
    fi
    log_event "DOWN" "PROCESS_RECOVERY_STARTED" "PROCESS" 0
    return 0
}

set_state() {
    local new_state="$1" new_reason="$2" pid="${3:-0}" sport="${4:-}" minrtt="${5:-}" rtt="${6:-}" outer="${7:-0}"
    if [[ "$STATE" != "$new_state" || "$REASON" != "$new_reason" ]]; then
        STATE="$new_state"; REASON="$new_reason"
        log_event "$STATE" "STATE_CHANGE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt"
    else
        STATE="$new_state"; REASON="$new_reason"
    fi
    write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" "$outer" "$REMOTE_OK" \
        "$DATA_PLANE_OK" "$DATA_PROBE_FAILS"
}

restart_gost_rate_limited() {
    local reason="$1" now
    now="$(now_epoch)"
    if (( LAST_RESTART > 0 && now - LAST_RESTART < ${RESTART_COOLDOWN_SEC:-300} )); then
        log_event "FAULT" "RESTART_SKIPPED_COOLDOWN" "$reason" "$LAST_PID" "$LAST_SPORT"
        return 1
    fi
    if [[ "$reason" == "DATA_PLANE_STALE_OUTER" ]] && ! allow_data_probe_restart "$now"; then
        return 3
    fi
    LAST_RESTART="$now"
    stop_anchor
    log_event "FAULT" "RESTART_GOST" "$reason" "$LAST_PID" "$LAST_SPORT"
    if ! systemctl restart "$UNIT"; then
        log_event "FAULT" "RESTART_GOST_FAILED" "$reason" "$LAST_PID" "$LAST_SPORT"
        return 2
    fi
    (( LAST_PID > 0 )) && LAST_NONZERO_PID="$LAST_PID"
    LAST_PID=0; LAST_SPORT=""; ZERO_SINCE=0; MULTI_SEEN=0
    reset_data_probe_state
    return 0
}

# v1 的 prewarm 已经负责：建立候选 Anchor -> 测 minrtt -> 慢路重抽 -> 成功后直接留下 Anchor。
run_select() {
    local mode="${1:-normal}" cause="${2:-SELECT}" rc pid count sport info minrtt rtt
    reset_data_probe_state
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
        write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" 1 "$REMOTE_OK" \
            "$DATA_PLANE_OK" "$DATA_PROBE_FAILS"
        return "$rc"
        ;;
      11)
        pid="$(get_main_pid)"; count="$(get_gost_outer_count "$pid")"
        sport="$(get_single_sport "$pid" 2>/dev/null || true)"
        info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
        STATE="DEGRADED"; REASON="ANCHOR"; LAST_PID="$pid"; LAST_SPORT="$sport"; LAST_ANCHOR_RETRY="$(now_epoch)"
        write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" "$count" "$REMOTE_OK" \
            "$DATA_PLANE_OK" "$DATA_PROBE_FAILS"
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
    reset_data_probe_state
    log_event "FAST" "ADOPT_EXISTING_FAST" "PATH" "$pid" "$sport" "$minrtt" "$rtt"
    write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" 1 "$REMOTE_OK" \
        "$DATA_PLANE_OK" "$DATA_PROBE_FAILS"
    save_runtime_state
}

if (( ADOPT_MODE == 1 )); then
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
        PROCESS_HEALTHY_SINCE=0
        (( PROCESS_DOWN_SINCE == 0 )) && PROCESS_DOWN_SINCE="$now"
        reset_data_probe_state
        DATA_PLANE_OK="no"
        set_state "DOWN" "PROCESS" "$pid" "" "" "" 0
        if (( now - PROCESS_DOWN_SINCE >= PROCESS_RECOVERY_GRACE_SEC )); then
            recover_process_rate_limited "$now" || true
        fi
        if [[ "$PROCESS_BREAKER_STATE" == "open" ]]; then
            set_state "FAULT" "PROCESS_BREAKER" "$pid" "" "" "" 0
        fi
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    PROCESS_DOWN_SINCE=0

    if (( PROCESS_HEALTHY_SINCE == 0 )); then
        PROCESS_HEALTHY_SINCE="$now"
    elif (( now - PROCESS_HEALTHY_SINCE >= PROCESS_RECOVERY_INTERVAL_SEC )); then
        close_process_breaker
    fi

    # 无可用 runtime（首次部署/重启 watchdog 且状态被清理/跨 reboot）：明确记录 COLD_START，不冒充 GOST 重启。
    if (( HAVE_RUNTIME == 0 )); then
        log_event "DOWN" "WATCHDOG_COLD_START" "INIT" "$pid"
        LAST_PID="$pid"; LAST_NONZERO_PID="$pid"; LAST_SPORT=""; ZERO_SINCE=0; MULTI_SEEN=0; REMOTE_OK="unknown"
        reset_data_probe_state
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
        reset_data_probe_state
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
        reset_data_probe_state
        DATA_PLANE_OK="no"
        ((MULTI_SEEN++)); set_state "FAULT" "MULTI_OUTER" "$pid" "" "" "" "$count"
        if (( MULTI_SEEN >= ${MULTI_CONFIRM_COUNT:-2} )); then restart_gost_rate_limited "MULTI_OUTER" || true; fi
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    else
        MULTI_SEEN=0
    fi

    if (( count == 0 )); then
        WARN_SINCE=0; CRIT_SINCE=0; RECOVER_SINCE=0; LAST_SPORT=""
        reset_data_probe_state
        DATA_PLANE_OK="no"
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

    # outer == 1。ESTAB 只证明 socket 仍存在，不能据此推断 Remote 或 MTCP 数据面健康。
    ZERO_SINCE=0; LAST_RECOVERY_ATTEMPT=0
    sport="$(get_single_sport "$pid" 2>/dev/null || true)"
    [[ -n "$sport" ]] || { save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue; }
    info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
    business="$(get_business_conn_count "$pid")"

    if [[ -z "$LAST_SPORT" ]]; then
        LAST_SPORT="$sport"
        reset_data_probe_state
        run_select normal "INITIAL_NO_SPORT" || true
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    if [[ "$LAST_SPORT" != "$sport" ]]; then
        old_sport="$LAST_SPORT"
        log_event "DOWN" "SESSION_CHANGED" "NEW_SPORT" "$pid" "$sport" "$minrtt" "$rtt" "old=$old_sport business=$business"
        LAST_SPORT="$sport"
        reset_data_probe_state
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
                    reset_data_probe_state
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

    # Data Plane Probe：outer=1 只能说明内核仍保留 ESTAB socket；只有通过
    # Anchor echo 回路收发 payload，才能证明当前 MTCP mux/outer 仍可用。
    if [[ "$DATA_PROBE_ENABLED" == "no" ]]; then
        if (( LAST_DATA_PROBE != 0 || DATA_PROBE_FAILS != 0 )) || \
           [[ "$DATA_PLANE_OK" != "unknown" || -n "$DATA_PROBE_SPORT" ]]; then
            reset_data_probe_state
        fi
        # 显式关闭新探测时保持旧版 outer=1 的兼容语义。
        close_data_probe_breaker
        REMOTE_OK="yes"
    else
        probe_threshold="$DATA_PROBE_FAIL_THRESHOLD"

        # 连续失败只对同一条 outer session 有效。
        if [[ -n "$DATA_PROBE_SPORT" && "$DATA_PROBE_SPORT" != "$sport" ]]; then
            reset_data_probe_state
        fi

        # 已确认整条 CN -> Remote 网络不可达时，只按 Remote 探测节奏等待；
        # Remote 恢复后再做一次 Data Probe，避免断网期间堆积超时 logical stream。
        if [[ "$DATA_PLANE_OK" == "no" && "$REMOTE_OK" == "no" ]] && \
           (( DATA_PROBE_FAILS >= probe_threshold )); then
            if (( LAST_REMOTE_PROBE == 0 || now - LAST_REMOTE_PROBE >= ${REMOTE_PROBE_INTERVAL_SEC:-15} )); then
                LAST_REMOTE_PROBE="$now"
                if remote_tcp_reachable; then
                    REMOTE_OK="yes"
                    log_event "DOWN" "REMOTE_TCP_UP" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt" \
                        "data_probe_failures=$DATA_PROBE_FAILS"

                    LAST_DATA_PROBE="$now"
                    DATA_PROBE_SPORT="$sport"
                    if data_plane_probe; then
                        previous_failures="$DATA_PROBE_FAILS"
                        DATA_PROBE_FAILS=0
                        DATA_PLANE_OK="yes"
                        close_data_probe_breaker
                        log_event "$STATE" "DATA_PROBE_RECOVERED" "DATA_PLANE" \
                            "$pid" "$sport" "$minrtt" "$rtt" "previous_failures=$previous_failures"
                    else
                        log_event "FAULT" "DATA_PROBE_FAILED" "DATA_PLANE" \
                            "$pid" "$sport" "$minrtt" "$rtt" \
                            "fail=$DATA_PROBE_FAILS/$probe_threshold after_remote_recovery=yes"
                        set_state "FAULT" "STALE_OUTER" "$pid" "$sport" "$minrtt" "$rtt" 1
                        log_event "FAULT" "STALE_OUTER_CONFIRMED" "DATA_PLANE" \
                            "$pid" "$sport" "$minrtt" "$rtt" \
                            "data_probe_failures=$DATA_PROBE_FAILS remote_tcp=up"
                        restart_gost_rate_limited "DATA_PLANE_STALE_OUTER"
                        restart_rc=$?
                        if (( restart_rc == 3 )); then
                            set_state "FAULT" "DATA_PROBE_BREAKER" "$pid" "$sport" "$minrtt" "$rtt" 1
                        fi
                        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
                    fi
                fi
            fi

            if [[ "$REMOTE_OK" == "no" ]]; then
                set_state "DOWN" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt" 1
                save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
            fi
        fi

        if (( LAST_DATA_PROBE == 0 || now - LAST_DATA_PROBE >= DATA_PROBE_INTERVAL_SEC )); then
            LAST_DATA_PROBE="$now"
            DATA_PROBE_SPORT="$sport"

            if data_plane_probe; then
                if (( DATA_PROBE_FAILS > 0 )) || [[ "$DATA_PLANE_OK" == "no" ]]; then
                    log_event "$STATE" "DATA_PROBE_RECOVERED" "DATA_PLANE" \
                        "$pid" "$sport" "$minrtt" "$rtt" "previous_failures=$DATA_PROBE_FAILS"
                fi
                DATA_PROBE_FAILS=0
                DATA_PLANE_OK="yes"
                REMOTE_OK="yes"
                close_data_probe_breaker
            else
                DATA_PLANE_OK="no"
                if (( DATA_PROBE_FAILS < probe_threshold )); then
                    DATA_PROBE_FAILS=$((DATA_PROBE_FAILS + 1))
                fi
                log_event "DEGRADED" "DATA_PROBE_FAILED" "DATA_PLANE" \
                    "$pid" "$sport" "$minrtt" "$rtt" \
                    "fail=$DATA_PROBE_FAILS/$probe_threshold"

                if (( DATA_PROBE_FAILS < probe_threshold )); then
                    set_state "DEGRADED" "DATA_PLANE" "$pid" "$sport" "$minrtt" "$rtt" 1
                    save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
                fi

                LAST_REMOTE_PROBE="$now"
                old_remote="$REMOTE_OK"
                if remote_tcp_reachable; then
                    REMOTE_OK="yes"
                    [[ "$old_remote" == "yes" ]] || \
                        log_event "DOWN" "REMOTE_TCP_UP" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt"
                    set_state "FAULT" "STALE_OUTER" "$pid" "$sport" "$minrtt" "$rtt" 1
                    log_event "FAULT" "STALE_OUTER_CONFIRMED" "DATA_PLANE" \
                        "$pid" "$sport" "$minrtt" "$rtt" \
                        "data_probe_failures=$DATA_PROBE_FAILS remote_tcp=up"
                    restart_gost_rate_limited "DATA_PLANE_STALE_OUTER"
                    restart_rc=$?
                    if (( restart_rc == 3 )); then
                        set_state "FAULT" "DATA_PROBE_BREAKER" "$pid" "$sport" "$minrtt" "$rtt" 1
                    fi
                else
                    REMOTE_OK="no"
                    [[ "$old_remote" == "no" ]] || \
                        log_event "DOWN" "REMOTE_TCP_DOWN" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt" \
                            "data_probe_failures=$DATA_PROBE_FAILS"
                    set_state "DOWN" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt" 1
                fi
                save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
            fi
        fi

        # 探测失败状态优先于 PATH/LIVE_RTT，避免下方状态机误覆盖为 FAST。
        if [[ "$DATA_PLANE_OK" == "no" ]]; then
            if [[ "$REMOTE_OK" == "no" ]]; then
                set_state "DOWN" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt" 1
            elif (( DATA_PROBE_FAILS >= probe_threshold )); then
                set_state "FAULT" "STALE_OUTER" "$pid" "$sport" "$minrtt" "$rtt" 1
            else
                set_state "DEGRADED" "DATA_PLANE" "$pid" "$sport" "$minrtt" "$rtt" 1
            fi
            save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
        fi
    fi

    LAST_SPORT="$sport"; LAST_PID="$pid"; LAST_NONZERO_PID="$pid"

    if [[ -z "$minrtt" ]]; then
        base_state="DEGRADED"; base_reason="TCP_INFO"
    elif is_lt "$minrtt" "$ACCEPT_RTT_MS"; then
        base_state="FAST"; base_reason="PATH"
    else
        base_state="DEGRADED"; base_reason="PATH"
    fi

    if [[ "$base_state" == "DEGRADED" ]]; then
        if (( LAST_DEGRADED_RETRY == 0 )); then LAST_DEGRADED_RETRY="$now"; fi
        if (( now - LAST_DEGRADED_RETRY >= ${DEGRADED_RETRY_SEC:-900} )); then
            if (( business == 0 )); then
                if (( BUSINESS_IDLE_SINCE == 0 )); then
                    BUSINESS_IDLE_SINCE="$now"
                elif (( now - BUSINESS_IDLE_SINCE >= BUSINESS_IDLE_HOLD_SEC )); then
                    LAST_DEGRADED_RETRY="$now"
                    log_event "DEGRADED" "DEGRADED_RETRY_IDLE" "PATH" "$pid" "$sport" "$minrtt" "$rtt" \
                        "idle_for=$((now - BUSINESS_IDLE_SINCE))s ports=$BUSINESS_PORTS"
                    run_select degraded-retry "DEGRADED_IDLE_RETRY" || true
                    BUSINESS_IDLE_SINCE=0
                    save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
                fi
            else
                BUSINESS_IDLE_SINCE=0
                LAST_DEGRADED_RETRY=$((now - ${DEGRADED_RETRY_SEC:-900} + ${DEGRADED_BUSY_DEFER_SEC:-60}))
                log_event "DEGRADED" "DEGRADED_RETRY_DEFER_BUSY" "PATH" "$pid" "$sport" "$minrtt" "$rtt" \
                    "business=$business ports=$BUSINESS_PORTS"
            fi
        fi
    else
        LAST_DEGRADED_RETRY=0; BUSINESS_IDLE_SINCE=0
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

### END CN_WATCHDOG ###
