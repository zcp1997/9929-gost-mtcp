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

VERSION="1.1.1"
INSTALL_BASE="${INSTALL_BASE:-/opt/gost-mtcp}"
GOST_VERSION="${GOST_VERSION:-v3.2.6}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
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
  9929-gost-mtcp 自包含安装器 v1.1.1

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
    install -m 755 "$tmp_dir/gost" "$dest_dir/gost"
    echo "✓ GOST 已安装到 $dest_dir/gost"
}

install_remote() {
    echo
    echo "==> 开始安装 Remote 端"
    echo

    check_command curl
    check_command tar
    check_command systemctl
    check_command socat

    local remote_dir="$INSTALL_BASE/remote"
    mkdir -p "$remote_dir"

    local mtcp_port
    prompt_read mtcp_port "Remote MTCP 监听端口 [6600]: " || die "未输入 MTCP 端口"
    mtcp_port="${mtcp_port:-6600}"
    [[ "$mtcp_port" =~ ^[0-9]+$ ]] && [[ "$mtcp_port" -ge 1 ]] && [[ "$mtcp_port" -le 65535 ]] || die "端口无效"
    [[ "$mtcp_port" -eq 12346 ]] && die "12346 被 Anchor endpoint 占用"

    download_gost "remote" "$remote_dir"

    echo "生成配置..."
    extract_embedded "REMOTE_YAML" | sed "s/:6600/:$mtcp_port/" > "$remote_dir/remote.yaml"

    echo "安装 systemd 服务..."
    extract_embedded "REMOTE_MAIN_SERVICE" | sed "s|__INSTALL_BASE__|$INSTALL_BASE|g" \
        > /etc/systemd/system/gost-mtcp-remote.service

    extract_embedded "REMOTE_ANCHOR_SERVICE" | sed "s|__INSTALL_BASE__|$INSTALL_BASE|g" \
        > /etc/systemd/system/gost-mtcp-remote-anchor.service

    systemctl daemon-reload
    systemctl enable --now gost-mtcp-remote.service
    systemctl enable --now gost-mtcp-remote-anchor.service

    sleep 2

    cat <<DONE

============================================================
  Remote 端安装完成
============================================================
MTCP 监听端口: $mtcp_port
配置文件: $remote_dir/remote.yaml

检查服务状态:
  systemctl status gost-mtcp-remote.service
  systemctl status gost-mtcp-remote-anchor.service
  ss -lntp | grep -E ':${mtcp_port}|:12346'

记录以下信息用于 CN 端配置:
  Remote 公网 IPv4: $(curl -s -4 -m 3 ifconfig.me 2>/dev/null || echo '<请手动确认>')
  Remote MTCP 端口: $mtcp_port

重要: 请在防火墙中只允许 CN 的公网 IP 访问端口 $mtcp_port
============================================================
DONE
}

install_cn() {
    echo
    echo "==> 开始安装 CN 端"
    echo

    check_command curl
    check_command tar
    check_command systemctl
    check_command ss
    check_command flock
    check_command timeout

    local cn_dir="$INSTALL_BASE/cn"
    mkdir -p "$cn_dir/state"

    local remote_alias remote_ip remote_port business_port anchor_port rtt_threshold unit_prefix

    echo "配置参数:"
    echo
    prompt_read remote_alias "Remote 线路别名（如 de、us，回车=default）: " || die "未输入线路别名"
    remote_alias="${remote_alias:-default}"
    [[ "$remote_alias" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || remote_alias="default"
    unit_prefix="gost-mtcp"
    [[ "$remote_alias" != "default" ]] && unit_prefix="gost-mtcp-${remote_alias}"

    while :; do
        prompt_read remote_ip "Remote IPv4 地址: " || die "未输入 Remote IPv4 地址"
        [[ "$remote_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        echo "  无效的 IPv4 地址" >&2
    done

    prompt_read remote_port "Remote MTCP 端口 [6600]: " || die "未输入 Remote MTCP 端口"
    remote_port="${remote_port:-6600}"

    prompt_read business_port "CN 业务监听端口 [12000]: " || die "未输入 CN 业务监听端口"
    business_port="${business_port:-12000}"

    prompt_read anchor_port "CN Anchor 监听端口 [12001]: " || die "未输入 CN Anchor 监听端口"
    anchor_port="${anchor_port:-12001}"

    prompt_read rtt_threshold "RTT 快路阈值（ms）[40]: " || die "未输入 RTT 阈值"
    rtt_threshold="${rtt_threshold:-40}"

    download_gost "cn" "$cn_dir"

    echo "生成配置文件..."
    extract_embedded "CN_YAML" | \
        sed "s/:12000/:$business_port/" | \
        sed "s/127.0.0.1:12001/127.0.0.1:$anchor_port/" | \
        sed "s/remote.example.invalid:6600/$remote_ip:$remote_port/" \
        > "$cn_dir/cn.yaml"

    local state_dir="$cn_dir/state"
    extract_embedded "CN_MTCP_CONF" | \
        sed "s/__MAIN_UNIT__/${unit_prefix}.service/g" | \
        sed "s/__ANCHOR_UNIT__/${unit_prefix}-anchor.service/g" | \
        sed "s/__REMOTE_IP__/$remote_ip/g" | \
        sed "s/__REMOTE_PORT__/$remote_port/g" | \
        sed "s/__BUSINESS_PORT__/$business_port/g" | \
        sed "s/__ANCHOR_PORT__/$anchor_port/g" | \
        sed "s/__RTT_THRESHOLD__/$rtt_threshold/g" | \
        sed "s|__STATE_DIR__|$state_dir|g" \
        > "$cn_dir/mtcp.conf"

    echo "安装运行脚本..."
    extract_embedded "CN_LIB" > "$cn_dir/mtcp-lib.sh"
    extract_embedded "CN_PREWARM" > "$cn_dir/mtcp-prewarm.sh"
    extract_embedded "CN_WATCHDOG" > "$cn_dir/mtcp-watchdog.sh"
    chmod +x "$cn_dir"/*.sh

    # 修正脚本中的硬编码路径
    sed -i "s|/opt/gost-mtcp|$INSTALL_BASE|g" "$cn_dir"/*.sh

    echo "安装 systemd 服务..."

    extract_embedded "CN_MAIN_SERVICE" | \
        sed "s|__INSTALL_BASE__|$INSTALL_BASE|g" | \
        sed "s/__UNIT_PREFIX__/$unit_prefix/g" \
        > "/etc/systemd/system/${unit_prefix}.service"

    extract_embedded "CN_ANCHOR_SERVICE" | \
        sed "s|__INSTALL_BASE__|$INSTALL_BASE|g" | \
        sed "s/__UNIT_PREFIX__/$unit_prefix/g" | \
        sed "s/127.0.0.1:12001/127.0.0.1:$anchor_port/" \
        > "/etc/systemd/system/${unit_prefix}-anchor.service"

    extract_embedded "CN_WATCHDOG_SERVICE" | \
        sed "s|__INSTALL_BASE__|$INSTALL_BASE|g" | \
        sed "s/__UNIT_PREFIX__/$unit_prefix/g" \
        > "/etc/systemd/system/${unit_prefix}-watchdog.service"

    systemctl daemon-reload
    systemctl enable --now "${unit_prefix}.service"
    systemctl enable --now "${unit_prefix}-watchdog.service"

    sleep 3

    cat <<DONE

============================================================
  CN 端安装完成
============================================================
线路: $remote_alias
Remote: $remote_ip:$remote_port
业务端口: $business_port (TCP)
RTT 阈值: ${rtt_threshold}ms

配置文件:
  $cn_dir/cn.yaml
  $cn_dir/mtcp.conf

检查服务:
  systemctl status ${unit_prefix}.service
  systemctl status ${unit_prefix}-watchdog.service

查看状态:
  cat $state_dir/status.json
  tail -f $state_dir/events.jsonl

查看 outer 连接:
  ss -tin state established 'dst $remote_ip dport = :$remote_port'

修改后端地址:
  编辑 $cn_dir/cn.yaml 中的 forwarder.nodes[0].addr
  然后执行: systemctl restart ${unit_prefix}.service

管理额外端口 Relay:
  bash standalone-install.sh relay
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
    elif [[ -r "$INSTALL_BASE/cn/cn.yaml" ]]; then
        CN_RELAY_YAML="$INSTALL_BASE/cn/cn.yaml"
    else
        CN_RELAY_YAML="$INSTALL_BASE/cn.yaml"
    fi
    if [[ -n "${CN_MTCP_CONFIG_PATH:-}" ]]; then
        CN_RELAY_CONFIG="$CN_MTCP_CONFIG_PATH"
    elif [[ -r "$INSTALL_BASE/cn/mtcp.conf" ]]; then
        CN_RELAY_CONFIG="$INSTALL_BASE/cn/mtcp.conf"
    else
        CN_RELAY_CONFIG="$INSTALL_BASE/mtcp.conf"
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
    local candidate="$1" action="$2" backup failed stamp restart_ok=0
    if ! validate_cn_relay_yaml "$candidate"; then
        rm -f "$candidate"
        die "生成的 cn.yaml 未通过结构检查，原配置未修改"
    fi

    stamp="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    backup="${CN_RELAY_YAML}.bak.$stamp"
    failed="${CN_RELAY_YAML}.failed.$stamp"
    cp -p "$CN_RELAY_YAML" "$backup"
    chmod 0644 "$candidate"
    mv -f "$candidate" "$CN_RELAY_YAML"

    echo "正在重启 ${CN_RELAY_UNIT}；现有业务连接会中断并由 Watchdog 重新 Prewarm。"
    if "$SYSTEMCTL_BIN" restart "$CN_RELAY_UNIT"; then
        sleep 1
        if "$SYSTEMCTL_BIN" is-active --quiet "$CN_RELAY_UNIT"; then
            restart_ok=1
        fi
    fi

    if (( restart_ok == 1 )); then
        echo "✓ $action"
        echo "备份: $backup"
        return 0
    fi

    echo "GOST 重启失败，正在回滚 $CN_RELAY_YAML" >&2
    cp -p "$CN_RELAY_YAML" "$failed"
    cp -p "$backup" "$CN_RELAY_YAML"
    "$SYSTEMCTL_BIN" restart "$CN_RELAY_UNIT" >/dev/null 2>&1 || true
    die "Relay 修改未生效；已恢复原配置。失败配置保存在: $failed"
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
# 嵌入文件内容
# ============================================================

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
Description=GOST MTCP Remote Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=__INSTALL_BASE__/remote/gost -D -C __INSTALL_BASE__/remote/remote.yaml
Restart=always
RestartSec=5
KillMode=process

[Install]
WantedBy=multi-user.target
### END REMOTE_MAIN_SERVICE ###

### BEGIN REMOTE_ANCHOR_SERVICE ###
[Unit]
Description=GOST MTCP Remote Anchor Endpoint
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
UNIT=__MAIN_UNIT__
ANCHOR_UNIT=__ANCHOR_UNIT__
DST=__REMOTE_IP__
PORT=__REMOTE_PORT__
BUSINESS_PORT=__BUSINESS_PORT__
ANCHOR_HOST=127.0.0.1
ANCHOR_PORT=__ANCHOR_PORT__
ACCEPT_RTT_MS=__RTT_THRESHOLD__

LIVE_RTT_WARN_MS=120
LIVE_RTT_CRIT_MS=250
LIVE_RTT_WARN_HOLD_SEC=30
LIVE_RTT_CRIT_HOLD_SEC=120
LIVE_RTT_RECOVER_MS=80
LIVE_RTT_RECOVER_HOLD_SEC=30

PREWARM_MAX_DRAWS=12
RECOVERY_PREWARM_DRAWS=8
DEGRADED_RETRY_DRAWS=4
PREWARM_NO_SESSION_ATTEMPTS=3
PREWARM_CONNECT_WAIT_SEC=2
PREWARM_STABLE_REQUIRED=2
PREWARM_STABLE_INTERVAL_SEC=1
PREWARM_KILL_WAIT_SEC=3
PREWARM_TOTAL_TIMEOUT_SEC=120

ANCHOR_START_TIMEOUT_SEC=10
ANCHOR_STABLE_REQUIRED=2
ANCHOR_STABLE_INTERVAL_SEC=2
ANCHOR_RETRY_SEC=60
DEGRADED_RETRY_SEC=900
DEGRADED_BUSY_DEFER_SEC=180

WATCH_INTERVAL_SEC=5
ZERO_GRACE_SEC=10
REMOTE_PROBE_INTERVAL_SEC=15
REMOTE_PROBE_TIMEOUT_SEC=5
REMOTE_PROBE_ATTEMPTS=2
DATA_PROBE_ENABLED=yes
DATA_PROBE_INTERVAL_SEC=15
DATA_PROBE_TIMEOUT_SEC=3
DATA_PROBE_FAIL_THRESHOLD=3
DOWN_RETRY_SEC=15
STUCK_RESTART_AFTER_SEC=1800
RESTART_COOLDOWN_SEC=60
MULTI_CONFIRM_COUNT=3

STATE_DIR=__STATE_DIR__
RETENTION_SEC=86400
### END CN_MTCP_CONF ###

### BEGIN CN_MAIN_SERVICE ###
[Unit]
Description=GOST MTCP CN Main Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=__INSTALL_BASE__/cn/gost -D -C __INSTALL_BASE__/cn/cn.yaml
Restart=always
RestartSec=5
KillMode=process

[Install]
WantedBy=multi-user.target
### END CN_MAIN_SERVICE ###

### BEGIN CN_ANCHOR_SERVICE ###
[Unit]
Description=GOST MTCP CN Anchor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/12001; printf "A" >&3; exec cat <&3 >/dev/null'
Restart=no
KillMode=process

[Install]
WantedBy=multi-user.target
### END CN_ANCHOR_SERVICE ###

### BEGIN CN_WATCHDOG_SERVICE ###
[Unit]
Description=GOST MTCP CN Watchdog
After=network-online.target __UNIT_PREFIX__.service
Wants=network-online.target
BindsTo=__UNIT_PREFIX__.service

[Service]
Type=simple
Environment=MTCP_LIB=__INSTALL_BASE__/cn/mtcp-lib.sh
Environment=MTCP_PREWARM=__INSTALL_BASE__/cn/mtcp-prewarm.sh
ExecStart=__INSTALL_BASE__/cn/mtcp-watchdog.sh __INSTALL_BASE__/cn/mtcp.conf
Restart=always
RestartSec=10
KillMode=process

[Install]
WantedBy=multi-user.target
### END CN_WATCHDOG_SERVICE ###

### BEGIN CN_LIB ###
#!/usr/bin/env bash
set -uo pipefail

CONFIG_DEFAULT="/opt/gost-mtcp/cn/mtcp.conf"
CONFIG_KEYS=(
    UNIT ANCHOR_UNIT DST PORT BUSINESS_PORT ANCHOR_HOST ANCHOR_PORT
    ACCEPT_RTT_MS
    LIVE_RTT_WARN_MS LIVE_RTT_CRIT_MS LIVE_RTT_WARN_HOLD_SEC
    LIVE_RTT_CRIT_HOLD_SEC LIVE_RTT_RECOVER_MS LIVE_RTT_RECOVER_HOLD_SEC
    PREWARM_MAX_DRAWS RECOVERY_PREWARM_DRAWS DEGRADED_RETRY_DRAWS
    PREWARM_NO_SESSION_ATTEMPTS PREWARM_CONNECT_WAIT_SEC PREWARM_STABLE_REQUIRED
    PREWARM_STABLE_INTERVAL_SEC PREWARM_KILL_WAIT_SEC PREWARM_TOTAL_TIMEOUT_SEC
    ANCHOR_START_TIMEOUT_SEC ANCHOR_STABLE_REQUIRED ANCHOR_STABLE_INTERVAL_SEC
    ANCHOR_RETRY_SEC DEGRADED_RETRY_SEC DEGRADED_BUSY_DEFER_SEC
    WATCH_INTERVAL_SEC ZERO_GRACE_SEC REMOTE_PROBE_INTERVAL_SEC
    REMOTE_PROBE_TIMEOUT_SEC REMOTE_PROBE_ATTEMPTS DOWN_RETRY_SEC
    DATA_PROBE_ENABLED DATA_PROBE_INTERVAL_SEC DATA_PROBE_TIMEOUT_SEC
    DATA_PROBE_FAIL_THRESHOLD
    STUCK_RESTART_AFTER_SEC RESTART_COOLDOWN_SEC MULTI_CONFIRM_COUNT
    STATE_DIR STATE_FILE STATUS_JSON EVENT_FILE RETENTION_SEC
)

load_config() {
    local cfg="${1:-$CONFIG_DEFAULT}"
    [[ -r "$cfg" ]] || { echo "config not readable: $cfg" >&2; return 1; }
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
    STATE_DIR="${STATE_DIR:-/opt/gost-mtcp/cn/state}"
    STATE_FILE="${STATE_FILE:-${STATE_DIR}/runtime.state}"
    STATUS_JSON="${STATUS_JSON:-${STATE_DIR}/status.json}"
    EVENT_FILE="${EVENT_FILE:-${STATE_DIR}/events.jsonl}"
    RETENTION_SEC="${RETENTION_SEC:-86400}"
    DATA_PROBE_ENABLED="${DATA_PROBE_ENABLED:-yes}"
    DATA_PROBE_INTERVAL_SEC="${DATA_PROBE_INTERVAL_SEC:-15}"
    DATA_PROBE_TIMEOUT_SEC="${DATA_PROBE_TIMEOUT_SEC:-3}"
    DATA_PROBE_FAIL_THRESHOLD="${DATA_PROBE_FAIL_THRESHOLD:-3}"
    case "$DATA_PROBE_ENABLED" in
      yes|no) ;;
      *) echo "DATA_PROBE_ENABLED must be yes or no in config: $cfg" >&2; return 1 ;;
    esac
    local probe_key
    for probe_key in DATA_PROBE_INTERVAL_SEC DATA_PROBE_TIMEOUT_SEC DATA_PROBE_FAIL_THRESHOLD; do
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
    [[ "$data_failures" =~ ^[0-9]+$ ]] || data_failures=0
    apid="$(get_anchor_pid)"; acount="$(get_anchor_conn_count "$apid")"
    business="$(get_business_conn_count "$pid")"
    if (( apid > 0 && acount == 1 )); then astate="up"; elif (( apid > 0 )); then astate="starting"; else astate="down"; fi
    epoch="$(now_epoch)"; ts="$(now_text)"; tmp="${STATUS_JSON}.tmp.$$"
    printf '{"epoch":%s,"ts":"%s","state":"%s","reason":"%s","unit":"%s","dst":"%s","port":%s,"pid":%s,"outer_count":%s,"sport":"%s","minrtt_ms":"%s","rtt_ms":"%s","remote_reachable":"%s","data_plane_reachable":"%s","data_probe_failures":%s,"anchor_unit":"%s","anchor_state":"%s","anchor_pid":%s,"anchor_connections":%s,"business_connections":%s}\n' \
      "$epoch" "$(json_escape "$ts")" "$(json_escape "$state")" "$(json_escape "$reason")" "$(json_escape "$UNIT")" \
      "$(json_escape "$DST")" "$PORT" "${pid:-0}" "${outer:-0}" "$(json_escape "$sport")" "$(json_escape "$minrtt")" "$(json_escape "$rtt")" \
      "$(json_escape "$remote")" "$(json_escape "$data_plane")" "$data_failures" "$(json_escape "$ANCHOR_UNIT")" "$astate" \
      "${apid:-0}" "${acount:-0}" "${business:-0}" > "$tmp"
    mv -f "$tmp" "$STATUS_JSON"
}
### END CN_LIB ###

### BEGIN CN_PREWARM ###
#!/usr/bin/env bash
set -uo pipefail

CONFIG="${1:-/opt/gost-mtcp/cn/mtcp.conf}"
LIB="${MTCP_LIB:-/opt/gost-mtcp/cn/mtcp-lib.sh}"
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
        write_status_json "DEGRADED" "PATH" "$pid" "$sport" "$minrtt" "$rtt" 1 "yes"
        log_event "DEGRADED" "PREWARM_KEEP_SLOW" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "mode=$MODE attempt=$attempt/$MAX_DRAWS"
        exit 10
    fi

    log_event "DEGRADED" "PREWARM_REJECT_SLOW" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "mode=$MODE attempt=$attempt/$MAX_DRAWS"

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
        candidate_sport=""; stable=0
        continue
    fi

    if ! kill_outer_sport "$pid" "$sport"; then
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

DEFAULT_CONFIG="${MTCP_CONFIG:-/opt/gost-mtcp/cn/mtcp.conf}"
CONFIG="${1:-$DEFAULT_CONFIG}"
ADOPT_MODE=0
if [[ "${1:-}" == "--adopt" ]]; then
    CONFIG="$DEFAULT_CONFIG"
    ADOPT_MODE=1
elif [[ "${2:-}" == "--adopt" ]]; then
    ADOPT_MODE=1
fi

LIB="${MTCP_LIB:-/opt/gost-mtcp/cn/mtcp-lib.sh}"
PREWARM="${MTCP_PREWARM:-/opt/gost-mtcp/cn/mtcp-prewarm.sh}"
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
    reset_data_probe_state
    HAVE_RUNTIME=0
}

reset_runtime_state

load_runtime_state() {
    local saved_boot_id
    [[ -r "$STATE_FILE" ]] || return 1
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
    if [[ ! "$LAST_DATA_PROBE" =~ ^[0-9]+$ || ! "$DATA_PROBE_FAILS" =~ ^[0-9]+$ ]] ||
       [[ "$DATA_PLANE_OK" != "yes" && "$DATA_PLANE_OK" != "no" && "$DATA_PLANE_OK" != "unknown" ]] ||
       [[ -n "$DATA_PROBE_SPORT" && ! "$DATA_PROBE_SPORT" =~ ^[0-9]+$ ]]; then
        reset_data_probe_state
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
LAST_DATA_PROBE='$LAST_DATA_PROBE'
DATA_PROBE_FAILS='$DATA_PROBE_FAILS'
DATA_PLANE_OK='$DATA_PLANE_OK'
DATA_PROBE_SPORT='$DATA_PROBE_SPORT'
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
        reset_data_probe_state
        DATA_PLANE_OK="no"
        set_state "DOWN" "PROCESS" "$pid" "" "" "" 0
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

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

    # outer=1 只能说明内核仍保留 ESTAB socket；通过 Anchor echo 回路
    # 收发 payload，才能证明当前 MTCP mux/outer 仍可用。
    if [[ "$DATA_PROBE_ENABLED" == "no" ]]; then
        if (( LAST_DATA_PROBE != 0 || DATA_PROBE_FAILS != 0 )) || \
           [[ "$DATA_PLANE_OK" != "unknown" || -n "$DATA_PROBE_SPORT" ]]; then
            reset_data_probe_state
        fi
        REMOTE_OK="yes"
    else
        probe_threshold="$DATA_PROBE_FAIL_THRESHOLD"

        if [[ -n "$DATA_PROBE_SPORT" && "$DATA_PROBE_SPORT" != "$sport" ]]; then
            reset_data_probe_state
        fi

        # 已确认 Remote 不可达时只探测 Remote；恢复后再确认一次数据面。
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
                        restart_gost_rate_limited "DATA_PLANE_STALE_OUTER" || true
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
                    restart_gost_rate_limited "DATA_PLANE_STALE_OUTER" || true
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
