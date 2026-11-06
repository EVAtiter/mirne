#!/usr/bin/env python3
# TS に字幕（ARIB STD-B24）の ES を足す（試験の素材用）。
#
# 使い方: scripts/add-captions.py <入力.ts> <出力.ts>
#
# 入力は make-fixtures.sh の av-sync.ts（2 秒ごとに 1 フレームだけ白く光る）。
#   - PMT に字幕の ES（stream_type 0x06・PID 0x130・ストリーム識別記述子の component_tag 0x30）を足し、CRC を付け直す
#   - 光るフレームの PTS ちょうどに「字幕 n です」（n は 1 から）を出す本文、その 1 秒後に画面消去（CS）だけの本文を置く。
#     見た目は n ごとに 7 通りを順に（STYLES：白・黄・半透明の黒の背景・中型・赤い縁取り・点滅・囲みと外字）。
#     管理データは 3 秒ごと
#   - 字幕の PES は、PCR がその PTS の 0.5 秒前を過ぎたところのヌルパケットと入れ替える（TS の長さと時刻は変わらない）
# ffmpeg は字幕を作れないので、PES を手で組み立てる。実在の放送の字幕は使わない。
import sys

PACKET = 188
CAPTION_PID = 0x130
CAPTION_TAG = 0x30
NULL_PID = 0x1FFF
# 90 kHz
SECOND = 90_000
FLASH_PERIOD = 2 * SECOND
CLEAR_AFTER = 1 * SECOND
MANAGEMENT_PERIOD = 3 * SECOND
SEND_AHEAD = SECOND // 2


def crc32(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


def crc16(data):
    # CRC-16-CCITT（データグループの CRC。mirne は確かめないが、形を本物に合わせる）
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def pid_of(packet):
    return (packet[1] & 0x1F) << 8 | packet[2]


def payload_of(packet):
    start = 4
    if packet[3] & 0x20:
        start = 5 + packet[4]
    return packet[start:] if packet[3] & 0x10 else b""


def pcr_of(packet):
    if packet[3] & 0x20 and packet[4] >= 7 and packet[5] & 0x10:
        b = packet[6:11]
        return b[0] << 25 | b[1] << 17 | b[2] << 9 | b[3] << 1 | b[4] >> 7
    return None


def pts_bytes(pts):
    return bytes([0x21 | ((pts >> 29) & 0x0E), (pts >> 22) & 0xFF, ((pts >> 14) & 0xFE) | 1, (pts >> 7) & 0xFF, ((pts << 1) & 0xFE) | 1])


def u24(n):
    return bytes([(n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF])


def data_group(group_id, data):
    body = bytes([group_id << 2, 0x00, 0x00, len(data) >> 8, len(data) & 0xFF]) + data
    return body + crc16(body).to_bytes(2, "big")


def management_group():
    # 時刻制御モード 0（自由）、1 言語（タグ 0・表示モード 0・jpn・表示書式 7 = 960×540 の横書き）、データユニットなし
    data = bytes([0x3F, 0x01, 0x10]) + b"jpn" + bytes([0x70]) + u24(0)
    return data_group(0x00, data)


def statement_group(text, drcs=b""):
    units = bytes([0x1F, 0x20]) + u24(len(text)) + text
    if drcs:
        # 2 バイトの DRCS-0 の図形（data_unit_parameter 0x31）
        units = bytes([0x1F, 0x31]) + u24(len(drcs)) + drcs + units
    return data_group(0x01, bytes([0x3F]) + u24(len(units)) + units)


# 外字の図形：36×36 の 2 階調（1 ビット）の丸。区点 0x21 0x21 の DRCS-0
DRCS_SIZE = 36


def drcs_circle():
    bits = []
    center = (DRCS_SIZE - 1) / 2
    for y in range(DRCS_SIZE):
        for x in range(DRCS_SIZE):
            distance = ((x - center) ** 2 + (y - center) ** 2) ** 0.5
            bits.append(1 if 10 <= distance <= 16 else 0)
    data = bytearray()
    for i in range(0, len(bits), 8):
        byte = 0
        for bit in bits[i:i + 8]:
            byte = byte << 1 | bit
        data.append(byte)
    # 文字数 1・区点・形の数 1・モード 1（2 階調）・depth 0・幅・高さ・図形
    return bytes([0x01, 0x21, 0x21, 0x01, 0x01, 0x00, DRCS_SIZE, DRCS_SIZE]) + bytes(data)


# 字幕の見た目（n ごとに順に使う）。どれも CS の後、APS の前に置く制御符号
STYLES = [
    ("白", b""),
    ("黄", bytes([0x83])),                                      # YLF
    ("半透明の黒の背景", bytes([0x90, 0x20, 0x44, 0x90, 0x51])),  # パレット 4・背景の色 1（CLUT 65 = 半透明の黒）
    ("中型", bytes([0x89])),                                     # MSZ（幅が半分）
    ("赤い縁取り", bytes([0x9B, 0x31, 0x3B, 0x31, 0x20, 0x63])),  # ORN 1;1（縁取りの色 1 = 赤）
    ("点滅", bytes([0x91, 0x40])),                               # FLC 正相
    ("囲みと外字", bytes([0x97, 0x4F])),                          # HLC 上下左右。文の後ろに外字を 1 つ
]


def jis(text):
    # 漢字の集合（G0・GL）の 2 バイト
    return text.encode("iso2022_jp")[3:-3]


def caption_text(number):
    style = STYLES[(number - 1) % len(STYLES)]
    out = bytes([0x0C])                        # CS
    out += style[1]
    out += bytes([0x1C, 0x40 + 7, 0x40 + 8])   # APS：7 行目・8 列目
    out += jis("字幕") + b"\x20"
    out += b"\x0e" + str(number).encode() + b"\x0f"  # LS1 で英数、LS0 で戻す
    out += b"\x20" + jis("です")
    if style[0] == "囲みと外字":
        # G1 に DRCS-0 を指示して LS1 で呼び出し、区点 0x21 0x21、LS0 で戻す
        out += b"\x1b\x24\x29\x20\x40" + b"\x0e\x21\x21\x0f"
    return out


def pes(pts, group):
    payload = bytes([0x80, 0xFF, 0xF0]) + group
    header = bytes([0x84, 0x80, 0x05]) + pts_bytes(pts)
    length = len(header) + len(payload)
    return bytes([0x00, 0x00, 0x01, 0xBD, length >> 8, length & 0xFF]) + header + payload


def packets_for(data, counter):
    """PES を TS パケットに分ける（足りない分は適応フィールドで埋める）"""
    out = []
    first = True
    while data:
        chunk = data[:184]
        data = data[184:]
        header = bytes([0x47, (0x40 if first else 0) | CAPTION_PID >> 8, CAPTION_PID & 0xFF])
        if len(chunk) == 184:
            packet = header + bytes([0x10 | counter]) + chunk
        else:
            stuffing = 183 - len(chunk)
            adaptation = bytes([stuffing]) + (bytes([0x00]) + b"\xff" * (stuffing - 1) if stuffing > 0 else b"")
            packet = header + bytes([0x30 | counter]) + adaptation + chunk
        assert len(packet) == PACKET
        out.append(packet)
        counter = (counter + 1) & 0x0F
        first = False
    return out, counter


def main():
    if len(sys.argv) != 3:
        sys.exit("使い方: add-captions.py <入力.ts> <出力.ts>")
    data = open(sys.argv[1], "rb").read()
    packets = [bytearray(data[n:n + PACKET]) for n in range(0, len(data) - PACKET + 1, PACKET)]

    # PAT から PMT の PID、PMT から映像の PID を知る
    pmt_pid = None
    for packet in packets:
        if pid_of(packet) == 0 and packet[1] & 0x40:
            section = payload_of(packet)[1:]
            pmt_pid = (section[10] & 0x1F) << 8 | section[11]
            break
    video_pid = None
    patched = 0
    for packet in packets:
        if pid_of(packet) != pmt_pid or not packet[1] & 0x40:
            continue
        start = 4 + (1 + packet[4] if packet[3] & 0x20 else 0)
        pointer = packet[start]
        at = start + 1 + pointer
        length = (packet[at + 1] & 0x0F) << 8 | packet[at + 2]
        section = bytes(packet[at:at + 3 + length])
        if video_pid is None:
            info = (section[10] & 0x0F) << 8 | section[11]
            offset = 12 + info
            while offset < len(section) - 4:
                if section[offset] == 0x02:
                    video_pid = (section[offset + 1] & 0x1F) << 8 | section[offset + 2]
                offset += 5 + ((section[offset + 3] & 0x0F) << 8 | section[offset + 4])
        # 字幕の ES を ES の並びの最後に足す（ストリーム識別記述子だけを付ける）
        entry = bytes([0x06, 0xE0 | CAPTION_PID >> 8, CAPTION_PID & 0xFF, 0xF0, 0x03, 0x52, 0x01, CAPTION_TAG])
        body = section[:-4] + entry
        new_length = len(body) - 3 + 4
        body = body[:1] + bytes([(body[1] & 0xF0) | new_length >> 8, new_length & 0xFF]) + body[3:]
        new_section = body + crc32(body).to_bytes(4, "big")
        assert at + len(new_section) <= PACKET, "PMT が 1 パケットに収まらない"
        packet[at:at + len(new_section)] = new_section
        for i in range(at + len(new_section), PACKET):
            packet[i] = 0xFF
        patched += 1

    # 光るフレームの時刻：映像の最初の PES 数個の PTS のうち最も小さいもの（t = 0 のフレーム）
    ptses = []
    for packet in packets:
        if pid_of(packet) == video_pid and packet[1] & 0x40:
            body = payload_of(packet)
            if body[7] & 0x80:
                b = body[9:14]
                ptses.append((b[0] >> 1 & 0x07) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1)
            if len(ptses) >= 8:
                break
    origin = min(ptses)

    # PCR の進みに沿って、送る時刻の来た字幕の PES をヌルパケットと入れ替える
    last_pcr = None
    end_pcr = None
    for packet in packets:
        if pid_of(packet) == video_pid and pcr_of(packet) is not None:
            end_pcr = pcr_of(packet)
    schedule = []  # (PTS, データグループ)
    t = origin + SECOND // 2
    while t < end_pcr:
        schedule.append((t, management_group()))
        t += MANAGEMENT_PERIOD
    number = 1
    t = origin + FLASH_PERIOD
    while t + CLEAR_AFTER < end_pcr:
        drcs = drcs_circle() if STYLES[(number - 1) % len(STYLES)][0] == "囲みと外字" else b""
        schedule.append((t, statement_group(caption_text(number), drcs)))
        schedule.append((t + CLEAR_AFTER, statement_group(bytes([0x0C]))))
        number += 1
        t += FLASH_PERIOD
    schedule.sort(key=lambda item: item[0])

    counter = 0
    pending = []
    inserted = 0
    for index, packet in enumerate(packets):
        pcr = pcr_of(packet) if pid_of(packet) == video_pid else None
        if pcr is not None:
            last_pcr = pcr
        while schedule and last_pcr is not None and last_pcr >= schedule[0][0] - SEND_AHEAD:
            pts, group = schedule.pop(0)
            more, counter = packets_for(pes(pts, group), counter)
            pending.extend(more)
        if pending and pid_of(packet) == NULL_PID:
            packets[index] = bytearray(pending.pop(0))
            inserted += 1
    open(sys.argv[2], "wb").write(b"".join(packets))
    print(f"PMT {patched} 個に字幕の ES を足した・字幕 {number - 1} 個・PES のパケット {inserted} 個（残り {len(pending) + len(schedule)}）")


if __name__ == "__main__":
    main()
