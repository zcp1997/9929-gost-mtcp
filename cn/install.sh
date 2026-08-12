#!/usr/bin/env bash
set -euo pipefail

BASE=/root/9929-gost-mtcp
CN_DIR="$BASE/cn"
GOST_REPO="go-gost/gost"
GOST_VERSION="${GOST_VERSION:-v3.2.6}"
GOST_TMP_DIR=""
CONFIG_TMP_FILES=()

cleanup_gost_tmp() {
    if [[ -n "$GOST_TMP_DIR" ]]; then
        rm -rf "$GOST_TMP_DIR"
    fi
    local tmp
    for tmp in "${CONFIG_TMP_FILES[@]}"; do
        rm -f "$tmp"
    done
}
trap cleanup_gost_tmp EXIT

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

valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

configure_remote_endpoint() {
    local remote_ip remote_port yaml_tmp conf_tmp

    while :; do
        if ! read -r -p "请输入 JP 端远端 IPv4 地址: " remote_ip; then
            echo "未输入远端 IPv4 地址，安装已取消。" >&2
            exit 1
        fi
        if valid_ipv4 "$remote_ip"; then
            break
        fi
        echo "IPv4 地址格式无效，请重新输入。" >&2
    done

    while :; do
        if ! read -r -p "请输入 JP 端 MTCP 端口 [11000]: " remote_port; then
            echo "未输入远端端口，安装已取消。" >&2
            exit 1
        fi
        remote_port="${remote_port:-11000}"
        if valid_port "$remote_port"; then
            break
        fi
        echo "端口必须是 1-65535 之间的数字，请重新输入。" >&2
    done

    yaml_tmp="$(mktemp "$CN_DIR/.cn.yaml.tmp.XXXXXX")"
    conf_tmp="$(mktemp "$CN_DIR/.mtcp.conf.tmp.XXXXXX")"
    CONFIG_TMP_FILES+=("$yaml_tmp" "$conf_tmp")

    awk -v remote_addr="$remote_ip:$remote_port" '
        /^[[:space:]]*-[[:space:]]name:[[:space:]]*jp-mtcp[[:space:]]*$/ {
            in_jp_node = 1
            print
            next
        }
        in_jp_node && /^[[:space:]]*addr:[[:space:]]*/ {
            sub(/addr:.*/, "addr: " remote_addr)
            updated = 1
            in_jp_node = 0
        }
        { print }
        END {
            if (updated != 1) {
                exit 1
            }
        }
    ' "$CN_DIR/cn.yaml" > "$yaml_tmp" || {
        echo "无法更新 cn.yaml 中的 jp-mtcp 地址。" >&2
        exit 1
    }

    awk -v remote_ip="$remote_ip" -v remote_port="$remote_port" '
        /^DST=/ {
            print "DST=\"" remote_ip "\""
            dst_updated = 1
            next
        }
        /^PORT=/ {
            print "PORT=\"" remote_port "\""
            port_updated = 1
            next
        }
        { print }
        END {
            if (dst_updated != 1 || port_updated != 1) {
                exit 1
            }
        }
    ' "$CN_DIR/mtcp.conf" > "$conf_tmp" || {
        echo "无法更新 mtcp.conf 中的远端地址。" >&2
        exit 1
    }

    mv -f "$yaml_tmp" "$CN_DIR/cn.yaml"
    mv -f "$conf_tmp" "$CN_DIR/mtcp.conf"
    echo "已将 CN 端远端配置为 ${remote_ip}:${remote_port}。"
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

    local tag="$GOST_VERSION" version arch asset base_url expected actual
    [[ -n "$tag" ]] || { echo "unable to resolve GOST release tag" >&2; exit 1; }
    [[ "$tag" == v* ]] || tag="v$tag"
    version="${tag#v}"
    arch="$(linux_arch)"
    asset="gost_${version}_linux_${arch}.tar.gz"
    base_url="https://github.com/$GOST_REPO/releases/download/$tag"
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
    install -m 755 "$GOST_TMP_DIR/gost" "$CN_DIR/gost"
    echo "Downloaded GOST $tag ($arch) from GitHub."
}

mkdir -p "$CN_DIR/state"
configure_remote_endpoint
download_gost

chmod 755 \
  "$CN_DIR/mtcp-lib.sh" \
  "$CN_DIR/mtcp-prewarm.sh" \
  "$CN_DIR/mtcp-watchdog.sh" \
  "$CN_DIR/cleanup-old-versions.sh" \
  "$CN_DIR/install.sh"

ln -sfn "$CN_DIR/9929-gost-mtcp.service" /etc/systemd/system/9929-gost-mtcp.service
ln -sfn "$CN_DIR/9929-gost-mtcp-anchor.service" /etc/systemd/system/9929-gost-mtcp-anchor.service
ln -sfn "$CN_DIR/9929-gost-mtcp-watchdog.service" /etc/systemd/system/9929-gost-mtcp-watchdog.service
systemctl daemon-reload

echo "9929-gost-mtcp installed under $BASE"
echo "未启动任何服务。Anchor unit 没有 [Install]，不要 enable。"
