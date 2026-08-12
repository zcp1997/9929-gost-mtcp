#!/usr/bin/env bash
set -euo pipefail

BASE=/root/9929-gost-mtcp
JP_DIR="$BASE/jp"
GOST_REPO="go-gost/gost"
GOST_VERSION="${GOST_VERSION:-v3.2.6}"
GOST_TMP_DIR=""

cleanup_gost_tmp() {
  if [[ -n "$GOST_TMP_DIR" ]]; then
    rm -rf "$GOST_TMP_DIR"
  fi
}
trap cleanup_gost_tmp EXIT

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
  install -m 755 "$GOST_TMP_DIR/gost" "$JP_DIR/gost"
  echo "Downloaded GOST $tag ($arch) from GitHub."
}

mkdir -p "$JP_DIR"
download_gost
command -v socat >/dev/null || { echo "missing socat" >&2; exit 1; }

chmod 755 "$JP_DIR/install.sh"
ln -sfn "$JP_DIR/9929-gost-mtcp-jp.service" /etc/systemd/system/9929-gost-mtcp-jp.service
ln -sfn "$JP_DIR/9929-gost-mtcp-anchor-endpoint.service" /etc/systemd/system/9929-gost-mtcp-anchor-endpoint.service
systemctl daemon-reload
systemctl enable --now 9929-gost-mtcp-jp.service
systemctl enable --now 9929-gost-mtcp-anchor-endpoint.service

echo "9929-gost-mtcp JP installed."
