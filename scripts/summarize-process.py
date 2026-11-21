#!/usr/bin/env python3
# scripts/measure-process.sh の記録をまとめる。
#
# 使い方: scripts/summarize-process.py <記録の CSV> [始まりの時刻 HH:MM:SS] [終わりの時刻 HH:MM:SS]
#   CPU の平均・中央・最大、メモリの最初・最後・最大と、時間あたりの増え方（最小二乗の傾き）を出す
import csv
import statistics
import sys

UNITS = {"B": 1 / (1024 * 1024), "K": 1 / 1024, "M": 1, "G": 1024}


def megabytes(text):
    """top の MEM（例: 85M・1234K・1.2G。末尾に + や - が付くことがある）を MB にする"""
    text = text.rstrip("+-")
    unit = text[-1]
    if unit in UNITS:
        return float(text[:-1]) * UNITS[unit]
    return float(text) / (1024 * 1024)


def seconds(clock):
    hours, minutes, secs = (int(part) for part in clock.split(":"))
    return hours * 3600 + minutes * 60 + secs


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__ or "使い方: summarize-process.py <CSV> [始まり] [終わり]")
    start = seconds(sys.argv[2]) if len(sys.argv) > 2 else None
    end = seconds(sys.argv[3]) if len(sys.argv) > 3 else None
    rows = []
    previous = None
    day_offset = 0
    with open(sys.argv[1], newline="") as handle:
        for row in csv.DictReader(handle):
            t = seconds(row["time"])
            if previous is not None and t + day_offset < previous:
                day_offset += 24 * 3600  # 日付をまたいだ
            t += day_offset
            previous = t
            if start is not None and t < start:
                continue
            if end is not None and t > end:
                continue
            rows.append((t, float(row["cpu_percent"]), megabytes(row["memory"])))
    if not rows:
        sys.exit("範囲に記録が無い")
    cpus = [cpu for _, cpu, _ in rows]
    memories = [memory for _, _, memory in rows]
    span_hours = (rows[-1][0] - rows[0][0]) / 3600
    print(f"記録 {len(rows)} 件・{span_hours * 60:.1f} 分")
    print(f"CPU: 平均 {statistics.mean(cpus):.1f}%・中央 {statistics.median(cpus):.1f}%・最大 {max(cpus):.1f}%（100% = 1 コア）")
    print(f"メモリ: 最初 {memories[0]:.0f} MB・最後 {memories[-1]:.0f} MB・最小 {min(memories):.0f} MB・最大 {max(memories):.0f} MB")
    if len(rows) >= 2 and span_hours > 0:
        times = [(t - rows[0][0]) / 3600 for t, _, _ in rows]
        mean_t = statistics.mean(times)
        mean_m = statistics.mean(memories)
        slope = sum((t - mean_t) * (m - mean_m) for t, m in zip(times, memories)) / sum((t - mean_t) ** 2 for t in times)
        print(f"メモリの増え方: {slope:+.1f} MB / 時（最小二乗の傾き）")


if __name__ == "__main__":
    main()
