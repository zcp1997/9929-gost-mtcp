#!/usr/bin/env bash
set -euo pipefail

# 项目唯一安装入口：负责角色选择、交互配置、GOST 下载和 systemd unit 安装。
# CN 与 Remote 的安装逻辑均封装在本文件中，角色目录只保留运行配置、脚本和 unit 模板。
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELECTED_ROLE=""

show_banner() {
    cat <<'EOF'
============================================================
  9929-gost-mtcp 统一安装向导
============================================================
EOF
}

show_role_guide() {
    cat <<'EOF'

请选择“当前这台服务器”承担的角色：

  1) CN（中国大陆入口端）
     - 部署在中国大陆
     - 接收本地业务连接
     - 连接一个或多个 Remote 节点并进行路径优选

  2) Remote（境外中转端）
     - 部署在韩国、美国等境外地区
     - 监听 MTCP 端口，默认 6600/tcp
     - 接收 CN 发起的 MTCP 连接

  q) 退出安装

说明：de、us 等名称是 Remote 节点/线路别名，不是 CN 地区。
建议先安装 Remote，再安装 CN；配置 CN 时需要 Remote 的 IPv4 地址和监听端口。
EOF
}

show_usage() {
    cat <<'EOF'
用法：
  bash install.sh             交互选择角色
  bash install.sh cn          直接安装 CN 端
  bash install.sh remote      直接安装 Remote 端
  bash install.sh --help      查看帮助

下载说明：
  CN 默认通过 https://ghfast.top/ 加速下载 GitHub Release。
  如需强制直连 GitHub：GITHUB_PROXY_PREFIX= bash install.sh cn
  Remote 默认直连；也可设置 GITHUB_PROXY_PREFIX 使用自定义前缀。
EOF
}

normalize_role() {
    case "${1:-}" in
        1|cn|CN|Cn|cN) printf '%s\n' "cn" ;;
        2|remote|REMOTE|Remote) printf '%s\n' "remote" ;;
        *) return 1 ;;
    esac
}

select_role_interactively() {
    local choice confirmation role_name

    show_role_guide
    while :; do
        if ! read -r -p "请选择角色 [1=CN, 2=Remote, q=退出]: " choice; then
            echo "未选择部署角色，安装已取消。" >&2
            exit 1
        fi
        case "$choice" in
            q|Q|quit|QUIT|exit|EXIT)
                echo "安装已取消。"
                exit 0
                ;;
        esac
        if ! SELECTED_ROLE="$(normalize_role "$choice")"; then
            echo "输入无效：请输入 1、2、cn、remote 或 q。" >&2
            continue
        fi

        if [[ "$SELECTED_ROLE" == "cn" ]]; then
            role_name="CN（中国大陆入口端）"
        else
            role_name="Remote（境外中转端）"
        fi
        while :; do
            if ! read -r -p "确认当前服务器安装 $role_name？[Y/n]: " confirmation; then
                echo "未确认部署角色，安装已取消。" >&2
                exit 1
            fi
            case "$confirmation" in
                ""|y|Y|yes|YES) return ;;
                n|N|no|NO)
                    SELECTED_ROLE=""
                    echo "请重新选择服务器角色。"
                    break
                    ;;
                q|Q|quit|QUIT|exit|EXIT)
                    echo "安装已取消。"
                    exit 0
                    ;;
                *) echo "输入无效：请输入 y、n 或 q。" >&2 ;;
            esac
        done
    done
}

show_next_steps() {
    case "$SELECTED_ROLE" in
        cn)
            cat <<'EOF'

已选择：CN（中国大陆入口端）
请先确认 Remote 已安装，并准备好它的公网 IPv4 和 MTCP 监听端口。
接下来将依次询问：
  1. Remote 节点/线路别名，例如 de、us
  2. Remote IPv4 地址和 MTCP 端口
  3. CN 业务监听端口和 Anchor 监听端口
  4. RTT 快路准入阈值，默认 40ms，可自定义

CN 安装完成后会自动启用并启动主服务与 Watchdog；Anchor 仍只由 Watchdog 控制。
GOST 默认通过 https://ghfast.top/https://github.com/... 下载，并继续校验官方 checksums.txt。
EOF
            ;;
        remote)
            cat <<'EOF'

已选择：Remote（境外中转端）
接下来将询问 Remote 的 MTCP 监听端口，直接回车使用 6600/tcp。
安装完成后会自动启用并重启 Remote 服务。
请放行所选 TCP 端口，并记录 Remote 公网 IPv4 与端口，供 CN 安装时填写。
EOF
            ;;
    esac
    if [[ "$SELECTED_ROLE" == "cn" ]]; then
        printf '\n开始安装 CN 端……\n\n'
    else
        printf '\n开始安装 Remote 端……\n\n'
    fi
}

# -----------------------------------------------------------------------------
# CN 安装实现
# -----------------------------------------------------------------------------
install_cn() {
    BASE="$PROJECT_ROOT"
    CN_DIR="$BASE/cn"
    SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
    GOST_REPO="go-gost/gost"
    GOST_VERSION="${GOST_VERSION:-v3.2.6}"
    # 使用 ${VAR-default} 而非 ${VAR:-default}，允许 GITHUB_PROXY_PREFIX= 显式关闭代理。
    GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX-https://ghfast.top/}"
    GOST_TMP_DIR=""
    CONFIG_TMP_FILES=()

    REMOTE_ALIAS=""
    ROUTE_LABEL="default"
    INSTANCE_DIR="$CN_DIR"
    YAML_CONFIG="$CN_DIR/cn.yaml"
    MTCP_CONFIG="$CN_DIR/mtcp.conf"
    STATE_DIR_PATH="$CN_DIR/state"
    MAIN_UNIT="9929-gost-mtcp.service"
    ANCHOR_UNIT="9929-gost-mtcp-anchor.service"
    WATCHDOG_UNIT="9929-gost-mtcp-watchdog.service"
    REMOTE_IP=""
    REMOTE_PORT=""
    BUSINESS_PORT=""
    ANCHOR_PORT=""
    ACCEPT_RTT_MS=""

    cleanup_gost_tmp() {
        if [[ -n "$GOST_TMP_DIR" ]]; then
            rm -rf "$GOST_TMP_DIR"
        fi
        local tmp
        if (( ${#CONFIG_TMP_FILES[@]} > 0 )); then
            for tmp in "${CONFIG_TMP_FILES[@]}"; do
                rm -f "$tmp"
            done
        fi
    }
    trap cleanup_gost_tmp EXIT

    check_dependencies() {
        local command_name
        local -a missing=()

        for command_name in awk cp curl flock grep install mktemp ss systemctl tar timeout; do
            command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
        done
        if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
            missing+=("sha256sum/shasum")
        fi
        if [[ ! -x /bin/bash ]]; then
            missing+=("/bin/bash")
        fi
        if (( ${#missing[@]} > 0 )); then
            echo "缺少依赖命令: ${missing[*]}" >&2
            exit 1
        fi
    }

    valid_ipv4() {
        local address="$1" octet
        local -a octets
        IFS=. read -r -a octets <<< "$address"
        [[ "${#octets[@]}" -eq 4 ]] || return 1
        for octet in "${octets[@]}"; do
            [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
            (( 10#$octet <= 255 )) || return 1
        done
    }

    normalize_ipv4() {
        local address="$1"
        local -a octets
        IFS=. read -r -a octets <<< "$address"
        printf '%d.%d.%d.%d\n' \
            "$((10#${octets[0]}))" "$((10#${octets[1]}))" \
            "$((10#${octets[2]}))" "$((10#${octets[3]}))"
    }

    valid_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ && ${#port} -le 10 ]] || return 1
        (( 10#$port >= 1 && 10#$port <= 65535 ))
    }

    valid_rtt_threshold() {
        local value="$1"
        [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ && ${#value} -le 10 ]] || return 1
        awk -v value="$value" 'BEGIN { exit !(value > 0) }'
    }

    valid_alias() {
        local alias="$1"
        [[ "$alias" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || return 1
        # 避免 Remote 别名主 unit 与其他线路的 Anchor/Watchdog unit 重名。
        case "$alias" in
            anchor|watchdog|*-anchor|*-watchdog) return 1 ;;
        esac
    }

    configure_remote_alias() {
        local input

        while :; do
            if ! read -r -p "请输入 Remote 节点别名（如 de、us，直接回车使用默认线路）: " input; then
                echo "未输入 Remote 节点别名，安装已取消。" >&2
                exit 1
            fi
            if [[ -z "$input" ]] || valid_alias "$input"; then
                break
            fi
            echo "Remote 别名必须以字母或数字开头，只能包含字母、数字、下划线和连字符，最长 32 个字符；不能使用 anchor/watchdog 角色后缀。" >&2
        done

        REMOTE_ALIAS="$input"
        if [[ -n "$REMOTE_ALIAS" ]]; then
            ROUTE_LABEL="$REMOTE_ALIAS"
            INSTANCE_DIR="$CN_DIR/instances/$REMOTE_ALIAS"
            YAML_CONFIG="$INSTANCE_DIR/cn.yaml"
            MTCP_CONFIG="$INSTANCE_DIR/mtcp.conf"
            STATE_DIR_PATH="$INSTANCE_DIR/state"
            MAIN_UNIT="9929-gost-mtcp-${REMOTE_ALIAS}.service"
            ANCHOR_UNIT="9929-gost-mtcp-${REMOTE_ALIAS}-anchor.service"
            WATCHDOG_UNIT="9929-gost-mtcp-${REMOTE_ALIAS}-watchdog.service"
        fi
    }

    ensure_instance_inactive() {
        local unit
        local -a active_units=()

        for unit in "$WATCHDOG_UNIT" "$ANCHOR_UNIT" "$MAIN_UNIT"; do
            if systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
                active_units+=("$unit")
            fi
        done
        if (( ${#active_units[@]} > 0 )); then
            echo "Remote 线路 ${ROUTE_LABEL} 仍有运行中的 unit: ${active_units[*]}" >&2
            echo "为避免 GOST 与 Watchdog 在重装期间读取到不一致的配置，请先停止该线路后重试：" >&2
            echo "  systemctl stop $WATCHDOG_UNIT $ANCHOR_UNIT $MAIN_UNIT" >&2
            exit 1
        fi
    }

    prepare_instance_files() {
        [[ -r "$CN_DIR/cn.yaml" ]] || { echo "配置模板不可读: $CN_DIR/cn.yaml" >&2; exit 1; }
        [[ -r "$CN_DIR/mtcp.conf" ]] || { echo "配置模板不可读: $CN_DIR/mtcp.conf" >&2; exit 1; }

        if [[ -n "$REMOTE_ALIAS" ]]; then
            mkdir -p "$INSTANCE_DIR"
            if [[ ! -e "$YAML_CONFIG" ]]; then
                cp -p "$CN_DIR/cn.yaml" "$YAML_CONFIG"
            elif [[ ! -f "$YAML_CONFIG" ]]; then
                echo "实例配置不是普通文件: $YAML_CONFIG" >&2
                exit 1
            fi
            if [[ ! -e "$MTCP_CONFIG" ]]; then
                cp -p "$CN_DIR/mtcp.conf" "$MTCP_CONFIG"
            elif [[ ! -f "$MTCP_CONFIG" ]]; then
                echo "实例配置不是普通文件: $MTCP_CONFIG" >&2
                exit 1
            fi
        fi

        mkdir -p "$STATE_DIR_PATH"
    }

    read_conf_value() {
        local key="$1" fallback="${2:-}" value
        value="$(awk -v key="$key" '
            index($0, key "=") == 1 {
                value = substr($0, length(key) + 2)
                sub(/^"/, "", value)
                sub(/"$/, "", value)
                print value
                exit
            }
        ' "$MTCP_CONFIG" 2>/dev/null || true)"
        printf '%s\n' "${value:-$fallback}"
    }

    prompt_port() {
        local prompt="$1" default_port="$2" output_var="$3" value

        while :; do
            if ! read -r -p "$prompt [$default_port]: " value; then
                echo "未输入端口，安装已取消。" >&2
                exit 1
            fi
            value="${value:-$default_port}"
            if valid_port "$value"; then
                value="$((10#$value))"
                printf -v "$output_var" '%s' "$value"
                return
            fi
            echo "端口必须是 1-65535 之间的数字，请重新输入。" >&2
        done
    }

    prompt_rtt_threshold() {
        local default_value="$1" value

        while :; do
            if ! read -r -p "请输入 RTT 快路准入阈值（毫秒，minrtt 小于该值视为快路） [$default_value]: " value; then
                echo "未输入 RTT 阈值，安装已取消。" >&2
                exit 1
            fi
            value="${value:-$default_value}"
            if valid_rtt_threshold "$value"; then
                ACCEPT_RTT_MS="$value"
                return
            fi
            echo "RTT 阈值必须是大于 0 的数字，例如 40 或 40.5，请重新输入。" >&2
        done
    }

    PORT_CONFLICT_CONFIG=""
    PORT_CONFLICT_KEY=""

    find_local_port_conflict() {
        local port="$1" config key value candidate
        local -a configs=()

        PORT_CONFLICT_CONFIG=""
        PORT_CONFLICT_KEY=""
        if [[ "$MTCP_CONFIG" != "$CN_DIR/mtcp.conf" ]] &&
           [[ -e "$SYSTEMD_DIR/9929-gost-mtcp.service" || -L "$SYSTEMD_DIR/9929-gost-mtcp.service" ]]; then
            configs+=("$CN_DIR/mtcp.conf")
        fi
        for config in "$CN_DIR"/instances/*/mtcp.conf; do
            [[ -f "$config" ]] && configs+=("$config")
        done

        (( ${#configs[@]} > 0 )) || return 1
        for config in "${configs[@]}"; do
            [[ "$config" == "$MTCP_CONFIG" ]] && continue
            for key in BUSINESS_PORT BUSINESS_PORTS ANCHOR_PORT; do
                value="$(awk -v key="$key" '
                    index($0, key "=") == 1 {
                        value = substr($0, length(key) + 2)
                        gsub(/^"|"$/, "", value)
                        print value
                        exit
                    }
                ' "$config" 2>/dev/null || true)"
                value="${value//,/ }"
                for candidate in $value; do
                    if valid_port "$candidate"; then
                        candidate="$((10#$candidate))"
                    fi
                    if [[ "$candidate" == "$port" ]]; then
                        PORT_CONFLICT_CONFIG="$config"
                        PORT_CONFLICT_KEY="$key"
                        return 0
                    fi
                done
            done
        done
        return 1
    }

    prompt_unique_local_port() {
        local prompt="$1" default_port="$2" output_var="$3"

        while :; do
            prompt_port "$prompt" "$default_port" "$output_var"
            if ! find_local_port_conflict "${!output_var}"; then
                return
            fi
            echo "端口 ${!output_var} 已被 $PORT_CONFLICT_CONFIG 中的 $PORT_CONFLICT_KEY 使用，请选择其他端口。" >&2
        done
    }

    configure_instance() {
        local remote_default remote_port_default business_port_default anchor_port_default accept_rtt_default
        local input yaml_tmp conf_tmp

        remote_default="$(read_conf_value DST "")"
        remote_port_default="$(read_conf_value PORT "6600")"
        business_port_default="$(read_conf_value BUSINESS_PORT "12000")"
        anchor_port_default="$(read_conf_value ANCHOR_PORT "12001")"
        accept_rtt_default="$(read_conf_value ACCEPT_RTT_MS "40")"
        valid_port "$remote_port_default" || remote_port_default="6600"
        valid_port "$business_port_default" || business_port_default="12000"
        valid_port "$anchor_port_default" || anchor_port_default="12001"
        valid_rtt_threshold "$accept_rtt_default" || accept_rtt_default="40"

        while :; do
            if valid_ipv4 "$remote_default"; then
                if ! read -r -p "请输入 Remote 端 IPv4 地址 [$remote_default]: " input; then
                    echo "未输入远端 IPv4 地址，安装已取消。" >&2
                    exit 1
                fi
                input="${input:-$remote_default}"
            else
                if ! read -r -p "请输入 Remote 端 IPv4 地址: " input; then
                    echo "未输入远端 IPv4 地址，安装已取消。" >&2
                    exit 1
                fi
            fi
            if valid_ipv4 "$input"; then
                REMOTE_IP="$(normalize_ipv4 "$input")"
                break
            fi
            echo "IPv4 地址格式无效，请重新输入。" >&2
        done

        prompt_port "请输入 Remote 端 MTCP 端口" "$remote_port_default" REMOTE_PORT
        prompt_unique_local_port "请输入 CN 端业务监听端口" "$business_port_default" BUSINESS_PORT
        while :; do
            prompt_unique_local_port "请输入 CN 端 Anchor 监听端口" "$anchor_port_default" ANCHOR_PORT
            if [[ "$ANCHOR_PORT" != "$BUSINESS_PORT" ]]; then
                break
            fi
            echo "Anchor 端口不能与业务监听端口相同，请重新输入。" >&2
        done
        prompt_rtt_threshold "$accept_rtt_default"

        yaml_tmp="$(mktemp "$INSTANCE_DIR/.cn.yaml.tmp.XXXXXX")"
        conf_tmp="$(mktemp "$INSTANCE_DIR/.mtcp.conf.tmp.XXXXXX")"
        CONFIG_TMP_FILES+=("$yaml_tmp" "$conf_tmp")

        awk \
            -v remote_addr="$REMOTE_IP:$REMOTE_PORT" \
            -v business_addr=":$BUSINESS_PORT" \
            -v anchor_addr="127.0.0.1:$ANCHOR_PORT" '
            /^[[:space:]]*-[[:space:]]name:[[:space:]]*tcp-entry[[:space:]]*$/ {
                target = "business"
                print
                next
            }
            /^[[:space:]]*-[[:space:]]name:[[:space:]]*mtcp-anchor[[:space:]]*$/ {
                target = "anchor"
                print
                next
            }
            /^chains:[[:space:]]*$/ {
                in_chains = 1
                print
                next
            }
            in_chains && /^[[:space:]]*addr:[[:space:]]*/ {
                sub(/addr:.*/, "addr: " remote_addr)
                remote_updated++
                in_chains = 0
                print
                next
            }
            target != "" && /^[[:space:]]*addr:[[:space:]]*/ {
                if (target == "business") {
                    replacement = business_addr
                    business_updated++
                } else if (target == "anchor") {
                    replacement = anchor_addr
                    anchor_updated++
                }
                sub(/addr:.*/, "addr: " replacement)
                target = ""
                print
                next
            }
            { print }
            END {
                if (business_updated != 1 || anchor_updated != 1 || remote_updated != 1) {
                    exit 1
                }
            }
        ' "$YAML_CONFIG" > "$yaml_tmp" || {
            echo "无法更新 $YAML_CONFIG 中的监听或远端地址。" >&2
            exit 1
        }

        awk \
            -v main_unit="$MAIN_UNIT" \
            -v anchor_unit="$ANCHOR_UNIT" \
            -v remote_ip="$REMOTE_IP" \
            -v remote_port="$REMOTE_PORT" \
            -v business_port="$BUSINESS_PORT" \
            -v anchor_port="$ANCHOR_PORT" \
            -v accept_rtt_ms="$ACCEPT_RTT_MS" \
            -v state_dir="$STATE_DIR_PATH" '
            BEGIN {
                values["UNIT"] = main_unit
                values["ANCHOR_UNIT"] = anchor_unit
                values["DST"] = remote_ip
                values["PORT"] = remote_port
                values["BUSINESS_PORT"] = business_port
                values["BUSINESS_PORTS"] = business_port
                values["ANCHOR_HOST"] = "127.0.0.1"
                values["ANCHOR_PORT"] = anchor_port
                values["ACCEPT_RTT_MS"] = accept_rtt_ms
                values["STATE_DIR"] = state_dir
                values["STATE_FILE"] = state_dir "/runtime.state"
                values["STATUS_JSON"] = state_dir "/status.json"
                values["EVENT_FILE"] = state_dir "/events.jsonl"
            }
            {
                separator = index($0, "=")
                key = separator > 0 ? substr($0, 1, separator - 1) : ""
                if (key in values) {
                    print key "=\"" values[key] "\""
                    updated[key]++
                    next
                }
                print
            }
            END {
                if (updated["BUSINESS_PORTS"] == 0) {
                    print "BUSINESS_PORTS=\"" values["BUSINESS_PORTS"] "\""
                    updated["BUSINESS_PORTS"] = 1
                }
                failed = 0
                for (key in values) {
                    if (updated[key] != 1) {
                        failed = 1
                    }
                }
                exit failed
            }
        ' "$MTCP_CONFIG" > "$conf_tmp" || {
            echo "无法更新 $MTCP_CONFIG 中的实例配置。" >&2
            exit 1
        }

        mv -f "$yaml_tmp" "$YAML_CONFIG"
        mv -f "$conf_tmp" "$MTCP_CONFIG"
        echo "已配置 CN → Remote 线路 ${ROUTE_LABEL}: Remote=${REMOTE_IP}:${REMOTE_PORT}, 业务端口=${BUSINESS_PORT}, Anchor 端口=${ANCHOR_PORT}, RTT 准入阈值=${ACCEPT_RTT_MS}ms。"
    }

    verify_rendered_systemd_unit() {
        local role="$1" unit_file="$2"

        case "$role" in
            main)
                grep -Fqx "WorkingDirectory=$CN_DIR" "$unit_file" &&
                grep -Fqx "ExecStart=$CN_DIR/gost -D -C $YAML_CONFIG" "$unit_file"
                ;;
            anchor)
                grep -Fqx "Requires=$MAIN_UNIT" "$unit_file" &&
                grep -Fq "/dev/tcp/127.0.0.1/$ANCHOR_PORT" "$unit_file"
                ;;
            watchdog)
                grep -Fqx "Environment=\"MTCP_LIB=$CN_DIR/mtcp-lib.sh\"" "$unit_file" &&
                grep -Fqx "ExecStart=$CN_DIR/mtcp-watchdog.sh $MTCP_CONFIG" "$unit_file"
                ;;
            *) return 1 ;;
        esac
    }

    render_systemd_unit() {
        local role="$1" destination="$2" template tmp description_suffix=""

        case "$role" in
            main) template="$CN_DIR/9929-gost-mtcp.service" ;;
            anchor) template="$CN_DIR/9929-gost-mtcp-anchor.service" ;;
            watchdog) template="$CN_DIR/9929-gost-mtcp-watchdog.service" ;;
            *) echo "未知 unit 类型: $role" >&2; exit 1 ;;
        esac
        [[ -r "$template" ]] || { echo "unit 模板不可读: $template" >&2; exit 1; }
        [[ -n "$REMOTE_ALIAS" ]] && description_suffix=" [remote:$REMOTE_ALIAS]"

        mkdir -p "$SYSTEMD_DIR"
        tmp="$(mktemp "$SYSTEMD_DIR/.${destination}.tmp.XXXXXX")"
        CONFIG_TMP_FILES+=("$tmp")

        awk \
            -v role="$role" \
            -v description_suffix="$description_suffix" \
            -v cn_dir="$CN_DIR" \
            -v yaml_config="$YAML_CONFIG" \
            -v mtcp_config="$MTCP_CONFIG" \
            -v main_unit="$MAIN_UNIT" \
            -v anchor_port="$ANCHOR_PORT" '
            function replace_literal(text, old, replacement, pos, result) {
                result = ""
                while ((pos = index(text, old)) > 0) {
                    result = result substr(text, 1, pos - 1) replacement
                    text = substr(text, pos + length(old))
                }
                return result text
            }
            {
                line = $0
                if (description_suffix != "" && line ~ /^Description=/) {
                    line = line description_suffix
                }
                if (role == "main") {
                    line = replace_literal(line, "/root/9929-gost-mtcp/cn/cn.yaml", yaml_config)
                } else if (role == "anchor") {
                    line = replace_literal(line, "9929-gost-mtcp.service", main_unit)
                    line = replace_literal(line, "/dev/tcp/127.0.0.1/12001", "/dev/tcp/127.0.0.1/" anchor_port)
                } else if (role == "watchdog") {
                    line = replace_literal(line, "9929-gost-mtcp.service", main_unit)
                    line = replace_literal(line, "/root/9929-gost-mtcp/cn/mtcp.conf", mtcp_config)
                }
                line = replace_literal(line, "/root/9929-gost-mtcp/cn", cn_dir)
                print line
            }
        ' "$template" > "$tmp" || {
            echo "无法生成 systemd unit: $destination" >&2
            exit 1
        }
        if ! verify_rendered_systemd_unit "$role" "$tmp"; then
            echo "生成的 systemd unit 校验失败: $destination" >&2
            exit 1
        fi

        chmod 0644 "$tmp"
        mv -f "$tmp" "$SYSTEMD_DIR/$destination"
    }

    install_systemd_units() {
        render_systemd_unit main "$MAIN_UNIT"
        render_systemd_unit anchor "$ANCHOR_UNIT"
        render_systemd_unit watchdog "$WATCHDOG_UNIT"
    }

    enable_and_start_cn_units() {
        echo "正在启用并启动 $MAIN_UNIT ……"
        if ! systemctl enable --now "$MAIN_UNIT"; then
            echo "主服务启动失败，请检查: systemctl status $MAIN_UNIT --no-pager" >&2
            exit 1
        fi

        echo "正在启用并启动 $WATCHDOG_UNIT ……"
        if ! systemctl enable --now "$WATCHDOG_UNIT"; then
            echo "Watchdog 启动失败；主服务可能仍在运行，请检查: systemctl status $WATCHDOG_UNIT --no-pager" >&2
            exit 1
        fi

        if ! systemctl is-active --quiet "$MAIN_UNIT"; then
            echo "主服务未保持 active，请检查: systemctl status $MAIN_UNIT --no-pager" >&2
            exit 1
        fi
        if ! systemctl is-active --quiet "$WATCHDOG_UNIT"; then
            echo "Watchdog 未保持 active，请检查: systemctl status $WATCHDOG_UNIT --no-pager" >&2
            exit 1
        fi
    }

    sha256_file() {
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$1" | awk '{print $1}'
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$1" | awk '{print $1}'
        else
            echo "missing sha256sum or shasum" >&2
            return 1
        fi
    }

    linux_arch() {
        case "$(uname -m)" in
            x86_64|amd64) echo amd64 ;;
            aarch64|arm64) echo arm64 ;;
            armv7l|armv7*) echo armv7 ;;
            armv6l|armv6*) echo armv6 ;;
            armv5tel|armv5*) echo armv5 ;;
            i386|i486|i586|i686) echo 386 ;;
            riscv64) echo riscv64 ;;
            loongarch64) echo loong64 ;;
            mips64el) echo mips64le_hardfloat ;;
            mips64) echo mips64_hardfloat ;;
            mipsel) echo mipsle_hardfloat ;;
            mips) echo mips_hardfloat ;;
            *) echo "unsupported Linux architecture: $(uname -m)" >&2; return 1 ;;
        esac
    }

    download_gost() {
        command -v curl >/dev/null 2>&1 || { echo "missing curl" >&2; exit 1; }
        command -v tar >/dev/null 2>&1 || { echo "missing tar" >&2; exit 1; }

        local tag="$GOST_VERSION" version arch asset upstream_base_url base_url expected actual gost_target_tmp source_name
        [[ -n "$tag" ]] || { echo "unable to resolve GOST release tag" >&2; exit 1; }
        [[ "$tag" == v* ]] || tag="v$tag"
        version="${tag#v}"
        arch="$(linux_arch)"
        asset="gost_${version}_linux_${arch}.tar.gz"
        upstream_base_url="https://github.com/$GOST_REPO/releases/download/$tag"
        if [[ -n "$GITHUB_PROXY_PREFIX" ]]; then
            base_url="${GITHUB_PROXY_PREFIX%/}/$upstream_base_url"
            source_name="GitHub via ${GITHUB_PROXY_PREFIX%/}"
        else
            base_url="$upstream_base_url"
            source_name="GitHub direct"
        fi
        GOST_TMP_DIR="$(mktemp -d)"

        curl -fsSL --retry 3 "$base_url/$asset" -o "$GOST_TMP_DIR/$asset"
        curl -fsSL --retry 3 "$base_url/checksums.txt" -o "$GOST_TMP_DIR/checksums.txt"
        expected="$(awk -v file="$asset" '$2 == file {print $1; exit}' "$GOST_TMP_DIR/checksums.txt")"
        [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || {
            echo "checksum entry missing for $asset" >&2
            exit 1
        }
        actual="$(sha256_file "$GOST_TMP_DIR/$asset")"
        [[ "$actual" == "$expected" ]] || {
            echo "checksum mismatch for $asset" >&2
            exit 1
        }
        tar -xzf "$GOST_TMP_DIR/$asset" -C "$GOST_TMP_DIR"
        [[ -f "$GOST_TMP_DIR/gost" ]] || { echo "GOST binary missing in $asset" >&2; exit 1; }
        chmod 755 "$GOST_TMP_DIR/gost"

        # 多个实例共享二进制；原子替换可保证正在运行的其他实例继续使用旧 inode。
        gost_target_tmp="$(mktemp "$CN_DIR/.gost.tmp.XXXXXX")"
        CONFIG_TMP_FILES+=("$gost_target_tmp")
        install -m 755 "$GOST_TMP_DIR/gost" "$gost_target_tmp"
        mv -f "$gost_target_tmp" "$CN_DIR/gost"
        echo "Downloaded GOST $tag ($arch) from $source_name."
    }

    check_dependencies
    configure_remote_alias
    ensure_instance_inactive
    prepare_instance_files
    configure_instance
    download_gost

    chmod 755 \
      "$CN_DIR/mtcp-lib.sh" \
      "$CN_DIR/mtcp-prewarm.sh" \
      "$CN_DIR/mtcp-watchdog.sh"

    install_systemd_units
    systemctl daemon-reload
    enable_and_start_cn_units

    echo "9929-gost-mtcp CN → Remote 线路 ${ROUTE_LABEL} 已安装并启动。"
    echo "配置文件: $YAML_CONFIG, $MTCP_CONFIG"
    echo "运行服务: $MAIN_UNIT, $WATCHDOG_UNIT"
    echo "状态文件: $STATE_DIR_PATH/status.json"
    echo "事件日志: $STATE_DIR_PATH/events.jsonl"
    echo "查看事件: tail -n 30 $STATE_DIR_PATH/events.jsonl"
    echo "Anchor unit $ANCHOR_UNIT 没有 [Install]，不要 enable。"
}

# -----------------------------------------------------------------------------
# Remote 安装实现
# -----------------------------------------------------------------------------
install_remote() {
    BASE="$PROJECT_ROOT"
    REMOTE_DIR="$BASE/remote"
    SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
    REMOTE_CONFIG="$REMOTE_DIR/remote.yaml"
    MAIN_UNIT="9929-gost-mtcp-remote.service"
    ANCHOR_UNIT="9929-gost-mtcp-remote-anchor-endpoint.service"
    GOST_REPO="go-gost/gost"
    GOST_VERSION="${GOST_VERSION:-v3.2.6}"
    GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX-}"
    GOST_TMP_DIR=""
    LISTEN_PORT=""
    SOCAT_BIN=""
    TMP_FILES=()

    cleanup_tmp_files() {
        local tmp
        if [[ -n "$GOST_TMP_DIR" ]]; then
            rm -rf "$GOST_TMP_DIR"
        fi
        if (( ${#TMP_FILES[@]} > 0 )); then
            for tmp in "${TMP_FILES[@]}"; do
                rm -f "$tmp"
            done
        fi
    }
    trap cleanup_tmp_files EXIT

    check_dependencies() {
        local command_name
        local -a missing=()

        for command_name in awk curl grep install mktemp readlink socat systemctl tar; do
            command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
        done
        if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
            missing+=("sha256sum/shasum")
        fi
        if [[ ! -x /bin/bash ]]; then
            missing+=("/bin/bash")
        fi
        if (( ${#missing[@]} > 0 )); then
            echo "缺少依赖命令: ${missing[*]}" >&2
            exit 1
        fi
        SOCAT_BIN="$(command -v socat)"
    }

    ensure_remote_inactive() {
        local unit
        local -a active_units=()
        for unit in "$ANCHOR_UNIT" "$MAIN_UNIT"; do
            systemctl is-active --quiet "$unit" >/dev/null 2>&1 && active_units+=("$unit")
        done
        if (( ${#active_units[@]} > 0 )); then
            echo "Remote 端仍有运行中的 unit: ${active_units[*]}" >&2
            echo "为避免运行进程与重装中的新配置错配，请先停止后重试：" >&2
            echo "  systemctl stop $ANCHOR_UNIT $MAIN_UNIT" >&2
            exit 1
        fi
    }

    cleanup_obsolete_project_units() {
        local unit_file target relative role_dir unit_name
        local -a unit_files=()

        for unit_file in "$SYSTEMD_DIR"/9929-gost-mtcp*.service; do
            [[ -L "$unit_file" ]] && unit_files+=("$unit_file")
        done
        (( ${#unit_files[@]} > 0 )) || return 0

        for unit_file in "${unit_files[@]}"; do
            target="$(readlink "$unit_file" 2>/dev/null || true)"
            case "$target" in
                "$BASE"/*)
                    relative="${target#"$BASE"/}"
                    role_dir="${relative%%/*}"
                    if [[ "$role_dir" != "cn" && "$role_dir" != "remote" ]]; then
                        unit_name="${unit_file##*/}"
                        systemctl disable --now "$unit_name" >/dev/null 2>&1 || true
                        rm -f "$unit_file"
                        echo "已清理旧版部署 unit: $unit_name"
                    fi
                    ;;
            esac
        done
    }

    valid_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ && ${#port} -le 10 ]] || return 1
        (( 10#$port >= 1 && 10#$port <= 65535 ))
    }

    read_current_port() {
        awk '
            /^[[:space:]]*-[[:space:]]name:[[:space:]]*mtcp-server[[:space:]]*$/ {
                in_service = 1
                next
            }
            in_service && /^[[:space:]]*addr:[[:space:]]*:/ {
                value = $0
                sub(/^[[:space:]]*addr:[[:space:]]*:/, "", value)
                sub(/[[:space:]]*$/, "", value)
                print value
                exit
            }
        ' "$REMOTE_CONFIG" 2>/dev/null || true
    }

    configure_listen_port() {
        local default_port input config_tmp

        [[ -r "$REMOTE_CONFIG" ]] || {
            echo "Remote 配置不可读: $REMOTE_CONFIG" >&2
            exit 1
        }
        default_port="$(read_current_port)"
        valid_port "$default_port" || default_port="6600"
        default_port="$((10#$default_port))"

        while :; do
            if ! read -r -p "请输入 Remote 端 MTCP 监听端口 [$default_port]: " input; then
                echo "未输入监听端口，安装已取消。" >&2
                exit 1
            fi
            input="${input:-$default_port}"
            if ! valid_port "$input"; then
                echo "端口必须是 1-65535 之间的数字，请重新输入。" >&2
                continue
            fi
            input="$((10#$input))"
            if [[ "$input" == "12346" ]]; then
                echo "端口 12346 已由本机 Anchor endpoint 使用，请选择其他端口。" >&2
                continue
            fi
            LISTEN_PORT="$input"
            break
        done

        config_tmp="$(mktemp "$REMOTE_DIR/.remote.yaml.tmp.XXXXXX")"
        TMP_FILES+=("$config_tmp")
        awk -v listen_addr=":$LISTEN_PORT" '
            /^[[:space:]]*-[[:space:]]name:[[:space:]]*mtcp-server[[:space:]]*$/ {
                in_service = 1
                print
                next
            }
            in_service && /^[[:space:]]*addr:[[:space:]]*/ {
                sub(/addr:.*/, "addr: " listen_addr)
                updated++
                in_service = 0
                print
                next
            }
            { print }
            END { if (updated != 1) exit 1 }
        ' "$REMOTE_CONFIG" > "$config_tmp" || {
            echo "无法更新 $REMOTE_CONFIG 中的 MTCP 监听端口。" >&2
            exit 1
        }
        mv -f "$config_tmp" "$REMOTE_CONFIG"
    }

    sha256_file() {
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$1" | awk '{print $1}'
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$1" | awk '{print $1}'
        else
            return 1
        fi
    }

    linux_arch() {
        case "$(uname -m)" in
            x86_64|amd64) echo amd64 ;;
            aarch64|arm64) echo arm64 ;;
            armv7l|armv7*) echo armv7 ;;
            armv6l|armv6*) echo armv6 ;;
            armv5tel|armv5*) echo armv5 ;;
            i386|i486|i586|i686) echo 386 ;;
            riscv64) echo riscv64 ;;
            loongarch64) echo loong64 ;;
            mips64el) echo mips64le_hardfloat ;;
            mips64) echo mips64_hardfloat ;;
            mipsel) echo mipsle_hardfloat ;;
            mips) echo mips_hardfloat ;;
            *) echo "unsupported Linux architecture: $(uname -m)" >&2; return 1 ;;
        esac
    }

    download_gost() {
        local tag="$GOST_VERSION" version arch asset upstream_base_url base_url expected actual target_tmp source_name

        [[ -n "$tag" ]] || { echo "unable to resolve GOST release tag" >&2; exit 1; }
        [[ "$tag" == v* ]] || tag="v$tag"
        version="${tag#v}"
        arch="$(linux_arch)"
        asset="gost_${version}_linux_${arch}.tar.gz"
        upstream_base_url="https://github.com/$GOST_REPO/releases/download/$tag"
        if [[ -n "$GITHUB_PROXY_PREFIX" ]]; then
            base_url="${GITHUB_PROXY_PREFIX%/}/$upstream_base_url"
            source_name="GitHub via ${GITHUB_PROXY_PREFIX%/}"
        else
            base_url="$upstream_base_url"
            source_name="GitHub direct"
        fi
        GOST_TMP_DIR="$(mktemp -d)"

        curl -fsSL --retry 3 "$base_url/$asset" -o "$GOST_TMP_DIR/$asset"
        curl -fsSL --retry 3 "$base_url/checksums.txt" -o "$GOST_TMP_DIR/checksums.txt"
        expected="$(awk -v file="$asset" '$2 == file {print $1; exit}' "$GOST_TMP_DIR/checksums.txt")"
        [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || {
            echo "checksum entry missing for $asset" >&2
            exit 1
        }
        actual="$(sha256_file "$GOST_TMP_DIR/$asset")"
        [[ "$actual" == "$expected" ]] || {
            echo "checksum mismatch for $asset" >&2
            exit 1
        }
        tar -xzf "$GOST_TMP_DIR/$asset" -C "$GOST_TMP_DIR"
        [[ -f "$GOST_TMP_DIR/gost" ]] || { echo "GOST binary missing in $asset" >&2; exit 1; }

        target_tmp="$(mktemp "$REMOTE_DIR/.gost.tmp.XXXXXX")"
        TMP_FILES+=("$target_tmp")
        install -m 755 "$GOST_TMP_DIR/gost" "$target_tmp"
        mv -f "$target_tmp" "$REMOTE_DIR/gost"
        echo "Downloaded GOST $tag ($arch) from $source_name."
    }

    verify_rendered_unit() {
        local role="$1" unit_file="$2"

        case "$role" in
            main)
                grep -Fqx "WorkingDirectory=$REMOTE_DIR" "$unit_file" &&
                grep -Fqx "ExecStart=$REMOTE_DIR/gost -D -C $REMOTE_CONFIG" "$unit_file"
                ;;
            anchor)
                grep -Fq "ExecStart=$SOCAT_BIN " "$unit_file" &&
                grep -Fq "TCP-LISTEN:12346,bind=127.0.0.1" "$unit_file"
                ;;
            *) return 1 ;;
        esac
    }

    render_systemd_unit() {
        local role="$1" destination="$2" template tmp

        case "$role" in
            main) template="$REMOTE_DIR/9929-gost-mtcp-remote.service" ;;
            anchor) template="$REMOTE_DIR/9929-gost-mtcp-remote-anchor-endpoint.service" ;;
            *) echo "未知 unit 类型: $role" >&2; exit 1 ;;
        esac
        [[ -r "$template" ]] || { echo "unit 模板不可读: $template" >&2; exit 1; }

        mkdir -p "$SYSTEMD_DIR"
        tmp="$(mktemp "$SYSTEMD_DIR/.${destination}.tmp.XXXXXX")"
        TMP_FILES+=("$tmp")
        awk -v remote_dir="$REMOTE_DIR" -v socat_bin="$SOCAT_BIN" '
            function replace_literal(text, old, replacement, pos, result) {
                result = ""
                while ((pos = index(text, old)) > 0) {
                    result = result substr(text, 1, pos - 1) replacement
                    text = substr(text, pos + length(old))
                }
                return result text
            }
            {
                line = replace_literal($0, "/root/9929-gost-mtcp/remote", remote_dir)
                line = replace_literal(line, "/usr/bin/socat", socat_bin)
                print line
            }
        ' "$template" > "$tmp"
        if ! verify_rendered_unit "$role" "$tmp"; then
            echo "生成的 systemd unit 校验失败: $destination" >&2
            exit 1
        fi
        chmod 0644 "$tmp"
        mv -f "$tmp" "$SYSTEMD_DIR/$destination"
    }

    install_systemd_units() {
        render_systemd_unit main "$MAIN_UNIT"
        render_systemd_unit anchor "$ANCHOR_UNIT"
    }

    mkdir -p "$REMOTE_DIR"
    check_dependencies
    ensure_remote_inactive
    cleanup_obsolete_project_units
    configure_listen_port
    download_gost
    install_systemd_units
    systemctl daemon-reload
    systemctl enable "$MAIN_UNIT"
    systemctl enable "$ANCHOR_UNIT"
    # restart 对未运行的 unit 也会执行 start；重装时确保加载新配置、二进制与 unit。
    systemctl restart "$MAIN_UNIT"
    systemctl restart "$ANCHOR_UNIT"

    echo "9929-gost-mtcp Remote 端安装完成，MTCP 监听端口: $LISTEN_PORT/tcp"
    echo "服务: $MAIN_UNIT, $ANCHOR_UNIT"
}

# --help 不需要 root 权限；其他安装路径必须以 root 执行。
main() {
    case "${1:-}" in
        -h|--help)
            show_banner
            show_role_guide
            printf '\n'
            show_usage
            exit 0
            ;;
        "") ;;
        *)
            if ! SELECTED_ROLE="$(normalize_role "$1")"; then
                echo "未知角色: $1" >&2
                show_usage >&2
                exit 2
            fi
            ;;
    esac

    if (( $# > 1 )); then
        echo "参数过多。" >&2
        show_usage >&2
        exit 2
    fi

    if (( EUID != 0 )); then
        echo "安装需要 root 权限，请执行：sudo bash install.sh${1:+ $1}" >&2
        exit 1
    fi

    show_banner
    if [[ -z "$SELECTED_ROLE" ]]; then
        select_role_interactively
    fi
    show_next_steps

    case "$SELECTED_ROLE" in
        cn) install_cn ;;
        remote) install_remote ;;
        *) echo "内部错误：未知角色 $SELECTED_ROLE" >&2; exit 2 ;;
    esac
}

main "$@"
