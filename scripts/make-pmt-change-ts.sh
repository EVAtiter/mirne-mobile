#!/bin/bash
# 番組の境目を模した合成の TS を作る（PlayerEngine が PMT の変化に追従するかを `play --file` で確かめる）。
#
#   scripts/make-pmt-change-ts.sh <出力先のディレクトリ>
#   build/symroot/Debug/mirne-mobile-probe play --file <出力先>/joined.ts --seconds 30
#
# 前半 8 秒：H.264 1440×1080i（MBAFF・上のフィールドが先）・AAC 2ch が 1 本。
# 後半 8 秒：同じ映像・AAC が 2 本（PID 0x101・0x102）。時刻は 8.1 秒ずらして続け、PMT の版を 1 に上げ、
# continuity_counter は前半から続ける（実際の放送の境目と同じく、欠けにしない）。
# 中身は ffmpeg の testsrc2 と正弦波だけで、放送の中身は含まない。
set -euo pipefail

out="${1:?出力先のディレクトリを指定する}"
mkdir -p "$out"
cd "$out"

common=(-pix_fmt yuv420p -c:v libx264 -profile:v high
        -x264-params interlaced=1:tff=1:keyint=15:min-keyint=15:bframes=2:scenecut=0 -b:v 4M
        -c:a aac -b:a 128k -ar 48000 -ac 2
        -mpegts_service_id 1 -mpegts_pmt_start_pid 0x1000 -mpegts_start_pid 0x100 -muxdelay 0 -muxpreload 0 -f mpegts)
video=(-f lavfi -i testsrc2=size=1440x1080:rate=30000/1001)

ffmpeg -hide_banner -loglevel error -y "${video[@]}" -f lavfi -i sine=frequency=1000:sample_rate=48000 \
    -t 8 -map 0:v -map 1:a "${common[@]}" a.ts
ffmpeg -hide_banner -loglevel error -y "${video[@]}" -f lavfi -i sine=frequency=1000:sample_rate=48000 \
    -f lavfi -i sine=frequency=500:sample_rate=48000 \
    -t 8 -map 0:v -map 1:a -map 2:a -output_ts_offset 8.1 "${common[@]}" b.ts

python3 -I - <<'PY'
def crc32(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc

pmt_pid = 0x1000
a = open('a.ts', 'rb').read()
b = bytearray(open('b.ts', 'rb').read())
assert len(a) % 188 == 0 and len(b) % 188 == 0
last = {}
for i in range(0, len(a), 188):
    pid = ((a[i + 1] & 0x1F) << 8) | a[i + 2]
    if a[i + 3] & 0x10:
        last[pid] = a[i + 3] & 0x0F
for i in range(0, len(b), 188):
    pid = ((b[i + 1] & 0x1F) << 8) | b[i + 2]
    if b[i + 3] & 0x10:
        cc = (last.get(pid, 15) + 1) & 0x0F
        b[i + 3] = (b[i + 3] & 0xF0) | cc
        last[pid] = cc
    if pid == pmt_pid and b[i + 1] & 0x40:
        assert b[i + 3] & 0x30 == 0x10      # ffmpeg の PSI にはアダプテーションフィールドが無い
        section = i + 5 + b[i + 4]
        length = ((b[section + 1] & 0x0F) << 8) | b[section + 2]
        b[section + 5] = (b[section + 5] & 0xC1) | (1 << 1)  # version_number = 1
        end = section + 3 + length
        b[end - 4:end] = crc32(bytes(b[section:end - 4])).to_bytes(4, 'big')
open('joined.ts', 'wb').write(a + bytes(b))
PY
rm a.ts b.ts
echo "→ $out/joined.ts"
