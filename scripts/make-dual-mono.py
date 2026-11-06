#!/usr/bin/env python3
# 二重音声（ARIB のデュアルモノ）の ADTS を、モノラルの ADTS 2 本から作る（試験の素材用）。
#
# 使い方: scripts/make-dual-mono.py <主のモノラル.aac> <副のモノラル.aac> <出力.aac>
#
# 放送の二重音声は、channel_configuration 2 の ADTS の 1 フレームに、単一チャンネル要素（SCE）が 2 つ入る
# （普通のステレオは 2 チャンネルの要素 CPE が 1 つ）。ffmpeg の AAC エンコーダはこの形を作れないので、
# モノラルで別々に符号化したフレームの中身を、ビットの単位でつなぎ直す:
#   主のフレームの中身（SCE タグ 0）＋ 副のフレームの中身（SCE のタグを 1 に書き換え）＋ END ＋ バイト境界までの 0
# 中身の終わりの END（0b111）は、その後ろがバイト境界までの 0 なので、最後の 1 のビットから見つけられる。
import sys

ID_SCE = 0b000
ID_FIL = 0b110
ID_END = 0b111


def frames(data):
    """ADTS のフレームを (ヘッダ, 中身) で順に返す（CRC 無しだけを扱う）"""
    offset = 0
    while offset + 7 <= len(data):
        if data[offset] != 0xFF or data[offset + 1] & 0xF0 != 0xF0:
            raise ValueError(f"ADTS の同期が無い: {offset}")
        if data[offset + 1] & 1 == 0:
            raise ValueError("CRC 付きの ADTS は扱わない")
        length = (data[offset + 3] & 0x03) << 11 | data[offset + 4] << 3 | data[offset + 5] >> 5
        yield data[offset:offset + 7], data[offset + 7:offset + length]
        offset += length


def to_bits(data):
    return [(byte >> (7 - i)) & 1 for byte in data for i in range(8)]


def to_bytes(bits):
    bits = bits + [0] * (-len(bits) % 8)
    return bytes(sum(bit << (7 - i) for i, bit in enumerate(bits[n:n + 8])) for n in range(0, len(bits), 8))


def value(bits, start, count):
    result = 0
    for bit in bits[start:start + count]:
        result = result << 1 | bit
    return result


def skip_fill(bits):
    """先頭の FIL 要素（ffmpeg は最初のフレームにエンコーダの名前を入れる）を飛ばした位置"""
    start = 0
    while value(bits, start, 3) == ID_FIL:
        count = value(bits, start + 3, 4)
        start += 7
        if count == 15:
            count += value(bits, start, 8) - 1
            start += 8
        start += count * 8
    return start


def elements_before_end(payload):
    """中身から、先頭の FIL を除き END より前のビット列を返す。SCE で始まることを確かめる"""
    bits = to_bits(payload)
    last_one = max(i for i, bit in enumerate(bits) if bit)
    end = last_one - 2
    if value(bits, end, 3) != ID_END:
        raise ValueError("END が見つからない")
    start = skip_fill(bits)
    if value(bits, start, 3) != ID_SCE:
        raise ValueError("先頭が SCE ではない（モノラルの ADTS を渡す）")
    return bits[start:end]


def adts_header(template, payload_length, channel_configuration):
    header = bytearray(template)
    frame_length = 7 + payload_length
    header[2] = (header[2] & 0xFE) | (channel_configuration >> 2)
    header[3] = ((channel_configuration & 0x3) << 6) | (header[3] & 0x3C) | (frame_length >> 11)
    header[4] = (frame_length >> 3) & 0xFF
    header[5] = ((frame_length & 0x7) << 5) | 0x1F   # adts_buffer_fullness = 0x7FF（可変）
    header[6] = 0xFC                                  # 同上の残り・number_of_raw_data_blocks_in_frame = 0
    return bytes(header)


def main():
    if len(sys.argv) != 4:
        sys.exit("使い方: make-dual-mono.py <主のモノラル.aac> <副のモノラル.aac> <出力.aac>")
    main_frames = list(frames(open(sys.argv[1], "rb").read()))
    sub_frames = list(frames(open(sys.argv[2], "rb").read()))
    output = bytearray()
    for (header, main), (_, sub) in zip(main_frames, sub_frames):
        main_bits = elements_before_end(main)
        sub_bits = elements_before_end(sub)
        # 副の SCE の element_instance_tag（id の後ろの 4 ビット）を 1 にする
        sub_bits[3:7] = [0, 0, 0, 1]
        payload = to_bytes(main_bits + sub_bits + [1, 1, 1])
        output += adts_header(header, len(payload), 2) + payload
    open(sys.argv[3], "wb").write(output)
    print(f"{min(len(main_frames), len(sub_frames))} フレーム")


if __name__ == "__main__":
    main()
