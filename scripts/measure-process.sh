#!/bin/bash
# 動いている mirne mobile の CPU 使用率とメモリを一定の間隔で記録する。
#
# 使い方: scripts/measure-process.sh [間隔の秒（既定 5）] [出力ファイル（既定 build/measure/process-<日時>.csv）]
#   止めるときは Ctrl-C（アプリが終わっても止まる）。まとめは scripts/summarize-process.py <出力ファイル>
#
# - CPU は top の %CPU（間隔の間の平均。100% = 1 コア）
# - メモリは top の MEM（物理フットプリント）
# - アプリの中身（番組名など）は読まない。数値と時刻だけを書く
set -euo pipefail

APP_PROCESS_NAME="mirne mobile"
DEFAULT_INTERVAL_SECONDS=5

interval="${1:-$DEFAULT_INTERVAL_SECONDS}"
output="${2:-build/measure/process-$(date +%Y%m%d-%H%M%S).csv}"

pid="$(pgrep -x "$APP_PROCESS_NAME" | head -1 || true)"
if [ -z "$pid" ]; then
    echo "「$APP_PROCESS_NAME」が動いていない" >&2
    exit 1
fi

mkdir -p "$(dirname "$output")"
echo "time,cpu_percent,memory" > "$output"
echo "記録する: pid $pid・${interval} 秒ごと → $output"
while kill -0 "$pid" 2>/dev/null; do
    # 1 回目の値は前の記録が無く 0 になるので、2 回目の値を使う
    sample="$(top -l 2 -s "$interval" -pid "$pid" -stats cpu,mem | tail -1)"
    cpu="$(echo "$sample" | awk '{print $1}')"
    memory="$(echo "$sample" | awk '{print $2}')"
    [ -n "$cpu" ] || continue
    line="$(date +%H:%M:%S),$cpu,$memory"
    echo "$line" >> "$output"
    echo "$line"
done
echo "アプリが終わった"
