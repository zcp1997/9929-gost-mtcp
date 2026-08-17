#!/bin/bash

HOST="103.201.131.7"
PORT="22"
COUNT="${1:-500}"
WAIT="0.15"

TMP="/tmp/ecmp_minrtt_$$.txt"
> "$TMP"

echo "Target: ${HOST}:${PORT}"
echo "Samples: ${COUNT}"
echo

for ((i=1; i<=COUNT; i++)); do
    # 创建一个新的 TCP flow
    exec {fd}<>/dev/tcp/$HOST/$PORT 2>/dev/null

    if [ $? -ne 0 ]; then
        echo "[$i/$COUNT] connect failed"
        continue
    fi

    # 等 TCP_INFO 稳定一点
    sleep "$WAIT"

    LINE=$(ss -tni "dst ${HOST}:${PORT}" 2>/dev/null | grep -m1 "minrtt:")

    MINRTT=$(echo "$LINE" | sed -n 's/.*minrtt:\([0-9.]*\).*/\1/p')
    SPORT=$(echo "$LINE" | sed -n "s/.*[^0-9]10\.[0-9.]*:\([0-9]*\).*${HOST}:${PORT}.*/\1/p")

    if [ -n "$MINRTT" ]; then
        echo "$MINRTT" >> "$TMP"
        printf "[%4d/%d] minrtt=%7s ms\n" "$i" "$COUNT" "$MINRTT"
    else
        printf "[%4d/%d] minrtt=N/A\n" "$i" "$COUNT"
    fi

    # 主动关闭当前 flow
    exec {fd}>&-
    exec {fd}<&-

    sleep 0.05
done

echo
echo "=============================="
echo " ECMP minRTT distribution"
echo "=============================="

TOTAL=$(wc -l < "$TMP")

if [ "$TOTAL" -eq 0 ]; then
    echo "No valid minrtt samples."
    rm -f "$TMP"
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
echo "Valid samples: $TOTAL / $COUNT"

rm -f "$TMP"
