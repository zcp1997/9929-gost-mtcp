#!/bin/bash

HOST="${HOST:-103.201.131.7}"
PORT="${PORT:-22}"
WAIT="${WAIT:-0.15}"
SS_BIN="${SS_BIN:-ss}"
TMP=""

cleanup() {
    if [ -n "$TMP" ]; then
        rm -f "$TMP"
    fi
}

socket_inode_from_link() {
    local link_target="$1"

    if [[ "$link_target" =~ ^socket:\[([0-9]+)\]$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

get_socket_inode() {
    local fd="$1"
    local link_target

    link_target=$(readlink "/proc/$$/fd/$fd") || return 1
    socket_inode_from_link "$link_target"
}

get_socket_endpoints() {
    local inode="$1"

    "$SS_BIN" -Hntie state established 2>/dev/null | awk -v inode="$inode" '
        {
            inode_matches = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "ino:" inode) {
                    inode_matches = 1
                    break
                }
            }
            if (!inode_matches)
                next

            endpoint_count = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /:[0-9]+$/) {
                    endpoints[++endpoint_count] = $i
                    if (endpoint_count == 2) {
                        print endpoints[1], endpoints[2]
                        exit
                    }
                }
            }
        }
    '
}

get_minrtt_for_flow() {
    local local_endpoint="$1"
    local peer_endpoint="$2"
    local local_addr local_port peer_addr peer_port filter

    local_addr="${local_endpoint%:*}"
    local_port="${local_endpoint##*:}"
    peer_addr="${peer_endpoint%:*}"
    peer_port="${peer_endpoint##*:}"

    [[ -n "$local_addr" && "$local_port" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$peer_addr" && "$peer_port" =~ ^[0-9]+$ ]] || return 1

    filter="src ${local_addr} sport = :${local_port} dst ${peer_addr} dport = :${peer_port}"
    "$SS_BIN" -Hntie "$filter" 2>/dev/null | awk '
        match($0, /minrtt:[0-9.]+/) {
            value = substr($0, RSTART, RLENGTH)
            sub(/^minrtt:/, "", value)
            print value
            exit
        }
    '
}

main() {
    local count="${1:-${COUNT:-500}}"
    local i fd inode endpoints local_endpoint peer_endpoint sport minrtt total

    TMP=$(mktemp "${TMPDIR:-/tmp}/ecmp_minrtt.XXXXXX") || exit 1
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM

    echo "Target: ${HOST}:${PORT}"
    echo "Samples: ${count}"
    echo

    for ((i=1; i<=count; i++)); do
        # 每次创建新的 TCP flow，并保留 FD 直到本次 TCP_INFO 读取完成。
        if ! exec {fd}<>"/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
            echo "[$i/$count] connect failed"
            continue
        fi

        # 等 TCP_INFO 稳定一点。
        sleep "$WAIT"

        # 通过当前 FD 的 socket inode 找到准确端点，再用完整四元组读取该 flow。
        inode=$(get_socket_inode "$fd" 2>/dev/null || true)
        endpoints=""
        if [ -n "$inode" ]; then
            endpoints=$(get_socket_endpoints "$inode")
        fi

        local_endpoint=""
        peer_endpoint=""
        if [ -n "$endpoints" ]; then
            read -r local_endpoint peer_endpoint <<< "$endpoints"
        fi

        sport="N/A"
        if [[ "$local_endpoint" == *:* ]]; then
            sport="${local_endpoint##*:}"
        fi

        minrtt=""
        if [ -n "$local_endpoint" ] && [ -n "$peer_endpoint" ]; then
            minrtt=$(get_minrtt_for_flow "$local_endpoint" "$peer_endpoint")
        fi

        if [ -n "$minrtt" ]; then
            echo "$minrtt" >> "$TMP"
            printf "[%4d/%d] sport=%5s minrtt=%7s ms\n" "$i" "$count" "$sport" "$minrtt"
        else
            printf "[%4d/%d] sport=%5s minrtt=N/A\n" "$i" "$count" "$sport"
        fi

        # 主动关闭当前 flow。
        exec {fd}>&-
        sleep 0.05
    done

    echo
    echo "=============================="
    echo " ECMP minRTT distribution"
    echo "=============================="

    total=$(wc -l < "$TMP")

    if [ "$total" -eq 0 ]; then
        echo "No valid minrtt samples."
        exit 1
    fi

    awk '
    {
        bucket=int($1 + 0.5)
        count[bucket]++
        sum += $1
    }
    END {
        for (b in count)
            printf "%d %.0f %.2f\n", b, count[b], count[b] * 100 / NR

        printf "__AVG__ %.3f\n", sum / NR
    }
    ' "$TMP" | sort -n | awk '
    $1 != "__AVG__" {
        printf "%3d ms : %5d  %6.2f%%\n", $1, $2, $3
    }
    $1 == "__AVG__" {
        avg=$2
    }
    END {
        if (avg != "")
            printf "\nAverage minrtt: %.3f ms\n", avg
    }
    '

    echo
    echo "Valid samples: $total / $count"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
