#!/usr/bin/env python3
# TS の中で、音声のパケットだけを後ろへずらす（試験の素材用）。
#
# 使い方: scripts/delay-audio-packets.py <入力.ts> <出力.ts> <音声の PID（16 進）> <ずらすパケット数>
#
# 放送の TS では、映像は表示の時刻よりずっと早く（復号のバッファのぶん）届き、音声は直前に届く。
# ffmpeg の多重化は映像と音声を時刻の順に交互に並べるので、生成素材ではこの差が出ない。
# 音声のパケットを、指定した数だけ後ろの位置へ移して、放送と同じ「音声が遅れて届く」並びにする
# （PTS・PCR は書き換えない。届く順番だけが変わる）。
import sys


def main():
    if len(sys.argv) != 5:
        sys.exit("使い方: delay-audio-packets.py <入力.ts> <出力.ts> <音声の PID（16 進）> <ずらすパケット数>")
    data = open(sys.argv[1], "rb").read()
    audio_pid = int(sys.argv[3], 16)
    delay = int(sys.argv[4])
    packets = [data[n:n + 188] for n in range(0, len(data) - 187, 188)]
    output = []
    # (出す位置, パケット) を出す位置の順に持つ
    held = []
    for index, packet in enumerate(packets):
        while held and held[0][0] <= index:
            output.append(held.pop(0)[1])
        pid = (packet[1] & 0x1F) << 8 | packet[2]
        if pid == audio_pid:
            held.append((index + delay, packet))
        else:
            output.append(packet)
    output.extend(packet for _, packet in held)
    open(sys.argv[2], "wb").write(b"".join(output))
    print(f"{len(packets)} パケット・音声を {delay} パケット後ろへ")


if __name__ == "__main__":
    main()
