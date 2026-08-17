#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT_DIR/standalone-install.sh"
GENERATED_MARKER="# === GENERATED EMBEDDED FILES: DO NOT EDIT ==="
MODE="${1:---write}"

case "$MODE" in
    --write|--check) ;;
    *) echo "usage: $0 [--write|--check]" >&2; exit 2 ;;
esac

tmp="$(mktemp "${TMPDIR:-/tmp}/standalone-install.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

awk -v marker="$GENERATED_MARKER" '
    { print }
    $0 == marker { found=1; exit }
    END { if (!found) exit 42 }
' "$TARGET" > "$tmp" || {
    echo "generated marker missing in $TARGET" >&2
    exit 1
}

emit_file() {
    local name="$1" source="$2"
    printf '\n### BEGIN %s ###\n' "$name" >> "$tmp"
    sed -e '${/^$/d;}' "$ROOT_DIR/$source" >> "$tmp"
    printf '\n### END %s ###\n' "$name" >> "$tmp"
}

emit_file REMOTE_YAML remote/remote.yaml
emit_file REMOTE_MAIN_SERVICE remote/gost-ecmp-pathlock-remote.service
emit_file REMOTE_ANCHOR_SERVICE remote/gost-ecmp-pathlock-remote-anchor-endpoint.service
emit_file CN_YAML cn/cn.yaml
emit_file CN_MTCP_CONF cn/mtcp.conf
emit_file CN_MAIN_SERVICE cn/gost-ecmp-pathlock.service
emit_file CN_ANCHOR_SERVICE cn/gost-ecmp-pathlock-anchor.service
emit_file CN_WATCHDOG_SERVICE cn/gost-ecmp-pathlock-watchdog.service
emit_file CN_LIB cn/mtcp-lib.sh
emit_file CN_PREWARM cn/mtcp-prewarm.sh
emit_file CN_WATCHDOG cn/mtcp-watchdog.sh

chmod 0755 "$tmp"
if [[ "$MODE" == "--check" ]]; then
    if ! cmp -s "$tmp" "$TARGET"; then
        echo "standalone-install.sh is stale; run scripts/generate-standalone.sh" >&2
        exit 1
    fi
    echo "standalone embedded files match canonical sources"
    exit 0
fi

mv -f "$tmp" "$TARGET"
trap - EXIT
echo "generated $TARGET"
