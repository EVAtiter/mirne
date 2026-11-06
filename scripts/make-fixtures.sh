#!/bin/bash
# 再生系の試験に使う TS を ffmpeg で生成し、build/fixtures/ に置く（実放送の素材は使わない。生成物は .gitignore 対象で、いつでも作り直せる）。
#
#   scripts/make-fixtures.sh
#
# 作るもの（どれも地上デジタル放送に近い形: MPEG-2 Video・インターレース・AAC 48 kHz）
#   av-sync.ts        1440×1080i・16:9・ステレオ。2 秒ごとに 1 フレームだけ白く光り、同時に 1 kHz の短い音が鳴る
#   resolution.ts     1440×1080i → 1920×1080i → 720×480i（各 10 秒）。途中でシーケンスヘッダが変わる
#   surround.ts       1440×1080i・5.1ch
#   pcr-jump.ts       av-sync を 2 本つなぎ、つなぎ目で時刻が 0 に戻る（PCR・PTS の不連続）
#   packet-loss.ts    av-sync から 0.1% のパケットを抜いたもの
#   two-services.ts   2 サービス（1024: カラーバー＋1 kHz、1025: 別の絵＋440 Hz）を 1 本の TS に多重
#   pmt-change.ts     1 サービス。10 秒目で PMT の版が 0 → 1 に上がり、音声の PID が 0x101 → 0x102 に変わる
#   long.ts           av-sync と同じ内容の 30 分版（長時間の再生の試験用。約 1.5 GB なので LONG=1 のときだけ作る）
#   dual-mono.ts      二重音声（主 1 kHz・副 440 Hz）。ステレオ 5 秒 → 二重音声 10 秒 → ステレオ 5 秒（番組の境目を模す）。
#                     ffmpeg は二重音声の形を作れないので、モノラル 2 本を scripts/make-dual-mono.py でつなぎ直す
#   late-audio.ts     av-sync の音声のパケットを約 1.5 秒ぶん後ろへずらし、頭を切ったもの（放送と同じく、映像が表示よりずっと早く、
#                     音声が直前に届く並びを、途中から受信した形で。scripts/delay-audio-packets.py）
#   motion.ts         2 つのフィールドを別の瞬間（1/59.94 秒ずれ）から作った本物のインターレース。白い棒が速く横に動く
#                     （ほかの素材は元が順次走査で、フィールドの間に動きが無いので、デインターレースの差が出ない）
#   multi-audio.ts    音声 ES が 2 本（0x101: 1 kHz のステレオ、0x102: 440 Hz の 5.1ch）。副音声・解説放送の切替を模す。
#                     ffmpeg はストリーム識別記述子（component_tag）を書かないので、PID で選ぶ道筋を通る
#   captions.ts       av-sync に字幕の ES（PID 0x130・component_tag 0x30）を足したもの。光るフレームの PTS ちょうどに
#                     「字幕 n です」を出し、1 秒後に消す（字幕の同期の計測。scripts/add-captions.py）。見た目は n ごとに
#                     白・黄・半透明の黒の背景・中型・赤い縁取り・点滅・囲みと外字の 7 通りを順に
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=build/fixtures
mkdir -p "$OUT"

# 放送に近い設定
FRAME_RATE=30000/1001
GOP=15                 # 0.5 秒ごとに I ピクチャ
VIDEO_BITRATE=14M
AUDIO_BITRATE=192k
FLASH_PERIOD=2         # 光と音の間隔（秒）
SERVICE_ID=1024        # 試験用。実在の局と関係ない
ffmpeg_common=(-hide_banner -loglevel error -y)
mpeg2_interlaced=(-c:v mpeg2video -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize 4M
                  -g "$GOP" -bf 2 -flags +ilme+ildct -alternate_scan 1)
ts_muxer=(-f mpegts -mpegts_service_id "$SERVICE_ID" -mpegts_pmt_start_pid 0x1f0
          -mpegts_start_pid 0x100 -pcr_period 40 -muxrate 18M)

# 1 区間を作る。引数: 出力 幅 高さ 秒数 音のチャンネル数 [時刻のずらし]
segment() {
    local output=$1 width=$2 height=$3 seconds=$4 channels=$5 offset=${6:-0}
    local flash="if(lt(mod(t\,$FLASH_PERIOD)\,1/29.97)\,1\,0)"
    local tone="if(lt(mod(t,$FLASH_PERIOD),0.05),0.5*sin(2*PI*1000*t),0)"
    local layout=stereo exprs="$tone|$tone"
    if [ "$channels" = 6 ]; then
        layout=5.1
        exprs="$tone|$tone|$tone|0|$tone|$tone"
    fi
    ffmpeg "${ffmpeg_common[@]}" \
        -f lavfi -i "testsrc2=size=${width}x${height}:rate=$FRAME_RATE" \
        -f lavfi -i "aevalsrc=exprs='$exprs':s=48000:c=$layout" \
        -t "$seconds" \
        -vf "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='$flash',setfield=tff,setdar=16/9" \
        "${mpeg2_interlaced[@]}" \
        -c:a aac -b:a "$AUDIO_BITRATE" -ar 48000 \
        -output_ts_offset "$offset" \
        "${ts_muxer[@]}" "$output"
}

echo "av-sync.ts"
segment "$OUT/av-sync.ts" 1440 1080 30 2

echo "resolution.ts"
segment "$OUT/.res-a.ts" 1440 1080 10 2 0
segment "$OUT/.res-b.ts" 1920 1080 10 2 10
segment "$OUT/.res-c.ts" 720 480 10 2 20
cat "$OUT/.res-a.ts" "$OUT/.res-b.ts" "$OUT/.res-c.ts" > "$OUT/resolution.ts"
rm -f "$OUT"/.res-*.ts

echo "surround.ts"
segment "$OUT/surround.ts" 1440 1080 20 6

echo "pcr-jump.ts"
cat "$OUT/av-sync.ts" "$OUT/av-sync.ts" > "$OUT/pcr-jump.ts"

echo "packet-loss.ts"
python3 -I - "$OUT/av-sync.ts" "$OUT/packet-loss.ts" <<'PYTHON'
import random, sys
# 再現できるように乱数を固定する
random.seed(20261103)
data = open(sys.argv[1], "rb").read()
kept = bytearray()
dropped = 0
for offset in range(0, len(data), 188):
    if random.random() < 0.001:
        dropped += 1
        continue
    kept += data[offset:offset + 188]
open(sys.argv[2], "wb").write(kept)
print(f"  {dropped} パケットを抜いた")
PYTHON

echo "two-services.ts"
ffmpeg "${ffmpeg_common[@]}" \
    -f lavfi -i "testsrc2=size=1440x1080:rate=$FRAME_RATE" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
    -f lavfi -i "smptehdbars=size=1440x1080:rate=$FRAME_RATE" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 20 \
    -map 0:v -map 1:a -map 2:v -map 3:a \
    -vf "setfield=tff,setdar=16/9" \
    "${mpeg2_interlaced[@]}" -c:a aac -b:a "$AUDIO_BITRATE" -ac 2 -ar 48000 \
    -program program_num=1024:title=A:st=0:st=1 -program program_num=1025:title=B:st=2:st=3 \
    -f mpegts -mpegts_pmt_start_pid 0x1f0 -mpegts_start_pid 0x100 -pcr_period 40 -muxrate 36M \
    "$OUT/two-services.ts"

echo "pmt-change.ts"
# 前半は音声 0x101、後半は音声 0x102。後半の PMT の版を 1 にして CRC を付け直す
segment "$OUT/.pmt-a.ts" 1440 1080 10 2 0
ffmpeg "${ffmpeg_common[@]}" -i "$OUT/.pmt-a.ts" -map 0 -c copy -streamid 0:0x100 -streamid 1:0x102 \
    -output_ts_offset 10 "${ts_muxer[@]}" "$OUT/.pmt-b.ts"
python3 -I - "$OUT/.pmt-b.ts" <<'PYTHON'
import sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
table = []
for i in range(256):
    v = i << 24
    for _ in range(8):
        v = ((v << 1) ^ 0x04C11DB7) if v & 0x80000000 else (v << 1)
    table.append(v & 0xFFFFFFFF)
def crc32(b):
    c = 0xFFFFFFFF
    for x in b:
        c = ((c << 8) & 0xFFFFFFFF) ^ table[((c >> 24) ^ x) & 0xFF]
    return c
patched = 0
for offset in range(0, len(data), 188):
    p = data[offset:offset + 188]
    pid = (p[1] & 0x1F) << 8 | p[2]
    if pid != 0x1F0 or not p[1] & 0x40:
        continue
    start = offset + 4 + (1 + p[4] if p[3] & 0x20 else 0)
    start += 1 + data[start]              # pointer_field
    if data[start] != 0x02:
        continue
    length = 3 + ((data[start + 1] & 0x0F) << 8 | data[start + 2])
    data[start + 5] = (data[start + 5] & 0xC1) | (1 << 1)   # version_number = 1
    crc = crc32(data[start:start + length - 4])
    data[start + length - 4:start + length] = crc.to_bytes(4, "big")
    patched += 1
open(path, "wb").write(data)
print(f"  PMT {patched} 個の版を 1 にした")
PYTHON
cat "$OUT/.pmt-a.ts" "$OUT/.pmt-b.ts" > "$OUT/pmt-change.ts"
rm -f "$OUT"/.pmt-*.ts

echo "dual-mono.ts"
# 音声は ADTS のまま作ってつなぐ（ADTS は 1 フレームずつ区切られているので、ファイルを続けるだけで境目になる）
for part in main:1000 sub:440; do
    ffmpeg "${ffmpeg_common[@]}" -f lavfi -i "sine=frequency=${part#*:}:sample_rate=48000" -t 10 \
        -c:a aac -b:a 96k -ac 1 -f adts "$OUT/.dual-${part%%:*}.aac"
done
ffmpeg "${ffmpeg_common[@]}" -f lavfi -i "sine=frequency=1000:sample_rate=48000" -t 5 \
    -c:a aac -b:a "$AUDIO_BITRATE" -ac 2 -f adts "$OUT/.dual-stereo.aac"
python3 scripts/make-dual-mono.py "$OUT/.dual-main.aac" "$OUT/.dual-sub.aac" "$OUT/.dual-dual.aac" > /dev/null
cat "$OUT/.dual-stereo.aac" "$OUT/.dual-dual.aac" "$OUT/.dual-stereo.aac" > "$OUT/.dual-all.aac"
ffmpeg "${ffmpeg_common[@]}" \
    -f lavfi -i "testsrc2=size=1440x1080:rate=$FRAME_RATE" \
    -i "$OUT/.dual-all.aac" \
    -t 20 -map 0:v -map 1:a \
    -vf "setfield=tff,setdar=16/9" \
    "${mpeg2_interlaced[@]}" -c:a copy \
    "${ts_muxer[@]}" "$OUT/dual-mono.ts"
rm -f "$OUT"/.dual-*.aac

echo "late-audio.ts"
# 18M の多重化で 18000 パケット ≒ 1.5 秒。頭の 20000 パケット（音声がまだ無いところ）を切る
python3 scripts/delay-audio-packets.py "$OUT/av-sync.ts" "$OUT/.late-audio.ts" 101 18000 > /dev/null
tail -c +$((20000 * 188 + 1)) "$OUT/.late-audio.ts" > "$OUT/late-audio.ts"
rm -f "$OUT/.late-audio.ts"

echo "motion.ts"
# 59.94p で作り、tinterlace で隣り合う 2 枚を 1 枚のフレームの上下のフィールドにする
ffmpeg "${ffmpeg_common[@]}" \
    -f lavfi -i "testsrc2=size=1440x1080:rate=60000/1001" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
    -t 10 \
    -vf "drawbox=x='mod(t*1440\,1320)':y=380:w=120:h=420:color=white:t=fill,tinterlace=mode=interleave_top,setfield=tff,setdar=16/9" \
    "${mpeg2_interlaced[@]}" -c:a aac -b:a "$AUDIO_BITRATE" -ac 2 -ar 48000 \
    "${ts_muxer[@]}" "$OUT/motion.ts"

echo "multi-audio.ts"
ffmpeg "${ffmpeg_common[@]}" \
    -f lavfi -i "testsrc2=size=1440x1080:rate=$FRAME_RATE" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 20 -map 0:v -map 1:a -map 2:a \
    -vf "setfield=tff,setdar=16/9" \
    "${mpeg2_interlaced[@]}" -c:a aac -b:a "$AUDIO_BITRATE" -ar 48000 -ac:a:0 2 -ac:a:1 6 \
    "${ts_muxer[@]}" "$OUT/multi-audio.ts"

echo "captions.ts"
python3 scripts/add-captions.py "$OUT/av-sync.ts" "$OUT/captions.ts" > /dev/null

if [ "${LONG:-0}" = 1 ]; then
    echo "long.ts"
    # 長時間の試験用なので、映像の帯域は控えめにする（内容の違いは試験の目的に関係しない）
    VIDEO_BITRATE=6M
    mpeg2_interlaced=(-c:v mpeg2video -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize 4M
                      -g "$GOP" -bf 2 -flags +ilme+ildct -alternate_scan 1)
    ts_muxer=(-f mpegts -mpegts_service_id "$SERVICE_ID" -mpegts_pmt_start_pid 0x1f0
              -mpegts_start_pid 0x100 -pcr_period 40 -muxrate 8M)
    segment "$OUT/long.ts" 1440 1080 1800 2
fi

ls -la "$OUT"
