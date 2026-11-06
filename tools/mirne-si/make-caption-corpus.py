#!/usr/bin/env python3
# 字幕の突き合わせの入力を作る：字幕 PES の中身（data_identifier から）を 1 行 1 つの 16 進で書く。
#
#   python3 -I tools/mirne-si/make-caption-corpus.py <出力> [件数] [乱数の種]
#
# 文字（漢字・平仮名・英数・カタカナ・記号・DRCS）、集合の指示と呼び出し、既定のマクロ、位置・大きさ・色・
# 点滅・囲み・くり返し・待ち・CSI（SWF・SDP・SDF・SSM・SHS・SVS・ORN・ACPS・RCS・SCR・PRA）、
# 管理データ・DRCS のデータユニット・時刻付きの本文を乱数で組み合わせる。ときどき途中で切ったり、でたらめなバイトを混ぜたりする。
# 実在の放送の字幕は使わない。
import random
import sys


def u24(n):
    return [(n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF]


def unit(parameter, body):
    return [0x1F, parameter] + u24(len(body)) + body


def csi(rng):
    finals = [0x53, 0x5F, 0x56, 0x57, 0x58, 0x59, 0x63, 0x61, 0x6E, 0x67, 0x68]
    final = rng.choice(finals)
    count = rng.choice([0, 1, 2, 2, 3])
    choices = {
        0x53: lambda: rng.choice([5, 6, 7, 8, 9, 10, 11, 12, 3, 0]),
        0x57: lambda: rng.choice([16, 20, 24, 30, 36, 18]),
        0x63: lambda: rng.choice([0, 1, 1, 107, 3, 215]),
    }
    params = [choices.get(final, lambda: rng.choice([0, 1, 4, 12, 24, 36, 60, 120, 480, 620, 960, 1920, 99999]))() for _ in range(count)]
    body = []
    for i, p in enumerate(params):
        if i:
            body.append(0x3B)
        body += list(str(p).encode())
    if rng.random() < 0.3:
        # 中間の文字（0x20）を入れる形
        body.append(0x20)
    return [0x9B] + body + [final]


def text_body(rng):
    out = []
    for _ in range(rng.randint(1, 40)):
        r = rng.random()
        if r < 0.35:
            # 漢字の集合（G0）の 2 バイト。GL・GR のどちらからも
            first = rng.choice([rng.randint(0x21, 0x2F), rng.randint(0x30, 0x4F), rng.randint(0x50, 0x74), 0x7A, 0x7C])
            second = rng.randint(0x21, 0x7E)
            if rng.random() < 0.3:
                out += [first | 0x80, second | 0x80]
            else:
                out += [first, second]
        elif r < 0.45:
            # 1 バイトの文字（GL か GR）
            out.append(rng.randint(0x21, 0x7E) | (0x80 if rng.random() < 0.5 else 0))
        elif r < 0.50:
            out.append(rng.choice([0x20, 0xA0]))
        elif r < 0.56:
            # 呼び出し
            out += rng.choice([[0x0E], [0x0F], [0x19], [0x1D], [0x1B, 0x6E], [0x1B, 0x6F], [0x1B, 0x7E], [0x1B, 0x7D], [0x1B, 0x7C]])
        elif r < 0.60:
            # マクロ（SS3 の後に 0x60〜0x6F）
            out += [0x1D, rng.randint(0x60, 0x6F)]
        elif r < 0.66:
            # 指示
            out += rng.choice([
                [0x1B, rng.randint(0x28, 0x2B), rng.choice([0x4A, 0x30, 0x31, 0x40, 0x32, 0x49, 0x36, 0x37, 0x38, 0x7F])],
                [0x1B, rng.randint(0x28, 0x2B), 0x20, rng.choice([0x41, 0x42, 0x4F, 0x70, 0x50])],
                [0x1B, 0x24, rng.choice([0x42, 0x39, 0x3A, 0x3B])],
                [0x1B, 0x24, rng.randint(0x29, 0x2B), rng.choice([0x42, 0x3B])],
                [0x1B, 0x24, rng.randint(0x28, 0x2B), 0x20, 0x40],
            ])
        elif r < 0.80:
            out += rng.choice([
                [0x08], [0x09], [0x0A], [0x0B], [0x0D], [0x0C],
                [0x16, rng.randint(0x40, 0x7F)],
                [0x1C, rng.randint(0x40, 0x4F), rng.randint(0x40, 0x5F)],
                [rng.randint(0x80, 0x87)],
                [rng.choice([0x88, 0x89, 0x8A])],
                [0x8B, rng.choice([0x60, 0x41, 0x44, 0x45, 0x40])],
                [0x90, 0x20, rng.randint(0x40, 0x47)],
                [0x90, rng.randint(0x40, 0x7F)],
                [0x91, rng.choice([0x40, 0x47, 0x4F])],
                [0x93, rng.choice([0x40, 0x41])],
                [0x97, rng.randint(0x40, 0x4F)],
                [0x98, rng.randint(0x40, 0x4A)],
                [0x9D, 0x20, rng.randint(0x40, 0x5A)],
                [0x92, 0x20, 0x40],
                [0x94, 0x40],
            ])
        elif r < 0.95:
            out += csi(rng)
        else:
            out.append(rng.randint(0, 255))
    return out


def drcs_body(rng, two_byte):
    count = rng.randint(1, 3)
    out = [count]
    for _ in range(count):
        if two_byte:
            out += [rng.randint(0x21, 0x23), rng.randint(0x21, 0x7E)]
        else:
            out += [rng.randint(0x41, 0x4F), rng.randint(0x21, 0x7E)]
        fonts = rng.randint(1, 2)
        out.append(fonts)
        for _ in range(fonts):
            mode = rng.choice([0x00, 0x01, 0x01, 0x02])
            depth = rng.choice([0, 0, 2, 14])
            width, height = rng.randint(1, 12), rng.randint(1, 12)
            levels = depth + 2
            bits = (levels - 1).bit_length()
            length = (width * height * bits + 7) // 8
            out += [rng.randint(0, 0x0F) << 4 | mode, depth, width, height] + [rng.randint(0, 255) for _ in range(length)]
    return out


def management(rng):
    tmd = rng.choice([0, 0, 1, 2])
    data = [tmd << 6 | 0x3F]
    if tmd == 2:
        data += [0x00, 0x00, 0x01, 0x00, 0x00]
    languages = rng.randint(0, 2)
    data.append(languages)
    for tag in range(languages):
        dmf = rng.choice([0, 0b1010, 0b1100, 0b1111])
        data.append(tag << 5 | 0x10 | dmf)
        if dmf in (0b1100, 0b1101, 0b1110):
            data.append(rng.randint(0, 255))
        data += list(b"jpn")
        data.append(rng.randint(0, 15) << 4 | rng.randint(0, 3) << 2 | rng.randint(0, 3))
    units = []
    if rng.random() < 0.8:
        setup = []
        for _ in range(rng.randint(1, 5)):
            setup += csi(rng)
        units += unit(0x20, setup)
    if rng.random() < 0.3:
        units += unit(0x31, drcs_body(rng, True))
    return data + u24(len(units)) + units


def statement(rng):
    tmd = rng.choice([0, 0, 0, 1, 2])
    data = [tmd << 6 | 0x3F]
    if tmd in (1, 2):
        data += [rng.randint(0, 0x23), rng.randint(0, 0x59), rng.randint(0, 0x59), rng.randint(0, 0x99), rng.randint(0, 0x9F)]
    units = []
    if rng.random() < 0.25:
        two_byte = rng.random() < 0.6
        units += unit(0x31 if two_byte else 0x30, drcs_body(rng, two_byte))
    for _ in range(rng.randint(1, 2)):
        units += unit(0x20, text_body(rng))
    if rng.random() < 0.05:
        units += unit(0x35, [rng.randint(0, 255) for _ in range(rng.randint(0, 8))])
    return data + u24(len(units)) + units


def group(rng):
    kind = 0x80 if rng.random() < 0.8 else 0x81
    if rng.random() < 0.12:
        group_id, data = rng.choice([0x00, 0x20]), management(rng)
    else:
        group_id, data = rng.choice([0x01, 0x01, 0x21, 0x02]), statement(rng)
    header = [kind, 0xFF, 0xF0]
    body = [group_id << 2, 0x00, 0x00] + [(len(data) >> 8) & 0xFF, len(data) & 0xFF] + data + [0x12, 0x34]
    out = header + body
    r = rng.random()
    if r < 0.04:
        out = out[:rng.randint(0, len(out))]
    elif r < 0.07:
        position = rng.randint(0, len(out) - 1)
        out[position] = rng.randint(0, 255)
    return out


def main():
    path = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
    rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 20261104)
    with open(path, "w") as f:
        for _ in range(count):
            f.write(bytes(group(rng)).hex() + "\n")
    print(f"{count} 件を書いた")


if __name__ == "__main__":
    main()
