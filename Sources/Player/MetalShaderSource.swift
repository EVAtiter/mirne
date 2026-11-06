import Foundation

/// 映像の描画に使う Metal のシェーダー。
///
/// ビルド時ではなく起動時に `MTLDevice.makeLibrary(source:)` でコンパイルする。
/// Xcode 26 以降は Metal Toolchain が別途ダウンロード（約 700 MB）になっていて、入っていない環境では
/// .metal ファイルがあるだけでビルドが失敗するため（実際に起きた）。ソースを公開したときに、
/// ビルドする人の環境に左右されない利点もある。
enum MetalShaderSource {
    static let video = #"""
#include <metal_stdlib>
using namespace metal;

// mirne の映像の描画。
//
// 1 段目（convertFrame）: VideoToolbox の 4:2:0（Y と CbCr の 2 平面・ビデオレンジ）を、
//   デインターレースしながら RGB の中間テクスチャ（元の画素数のまま）に書く。
// 2 段目（presentVertex / presentFragment）: 中間テクスチャを、表示のアスペクト比に合わせて画面へ拡大・縮小する。
//
// インターレースの 4:2:0 では、色差の行もフィールドごとに交互に並ぶ。
// フィールド f の輝度の i 行目（元の行 2i+f）に対応する色差は、色差の 2*(i/2)+f 行目。

struct ConvertParameters {
    // 0 = 織り込み（weave）、1 = フィールドを拡大（bob）、2 = 動き適応（yadif と同じ考え方）
    uint mode;
    // 表示するフィールド（0 = トップ、1 = ボトム）
    uint field;
    // 1 = 元がプログレッシブ（色差の行をフィールドで分けない）
    uint progressive;
    // 1 = 表示するフィールドが、そのフレームの時間的に先のフィールド
    uint firstField;
};

// BT.709・ビデオレンジ（Y 16〜235、C 16〜240）から RGB へ
static float3 bt709(float y, float2 c) {
    float luma = (y - 16.0 / 255.0) * (255.0 / 219.0);
    float cb = (c.x - 128.0 / 255.0) * (255.0 / 224.0);
    float cr = (c.y - 128.0 / 255.0) * (255.0 / 224.0);
    return saturate(float3(luma + 1.5748 * cr,
                           luma - 0.1873 * cb - 0.4681 * cr,
                           luma + 1.8556 * cb));
}

// 輝度の行 row（そのフィールドに属する行）に対応する色差の行
static uint chromaRow(uint row, uint chromaHeight, bool progressive) {
    if (progressive) {
        return min(row / 2, chromaHeight - 1);
    }
    uint field = row & 1;
    uint index = row >> 1;
    return min(2 * (index >> 1) + field, chromaHeight - 1);
}

// 動き適応: 表示するフィールドの行はそのまま使い、もう一方のフィールドの行（欠けた行）だけを作る。
// 上下の行から補った値（空間）を、前後のフレームの同じ行の平均（時間）の近くに収める。
// 前後で変化が小さい所は時間の値、つまり 2 つのフィールドを合わせた縦の解像度になり、
// 動く所は上下からの補間になる（yadif の mode 0 から、斜めの縁を探す処理を除いたもの）。
static float adaptiveLuma(texture2d<float, access::read> current,
                          texture2d<float, access::read> previous,
                          texture2d<float, access::read> next,
                          uint x, uint y, uint height, bool firstField) {
    uint up = y == 0 ? y + 1 : y - 1;
    uint down = y + 1 >= height ? y - 1 : y + 1;
    float c = current.read(uint2(x, up)).r;
    float e = current.read(uint2(x, down)).r;
    // 欠けた行を持つ、時間的に前後のフィールド
    float before = firstField ? previous.read(uint2(x, y)).r : current.read(uint2(x, y)).r;
    float after = firstField ? current.read(uint2(x, y)).r : next.read(uint2(x, y)).r;
    float temporal = (before + after) * 0.5;
    float differenceAcross = abs(before - after);
    float differencePrevious = (abs(previous.read(uint2(x, up)).r - c) + abs(previous.read(uint2(x, down)).r - e)) * 0.5;
    float differenceNext = (abs(next.read(uint2(x, up)).r - c) + abs(next.read(uint2(x, down)).r - e)) * 0.5;
    float allowance = max(differenceAcross * 0.5, max(differencePrevious, differenceNext));
    float spatial = (c + e) * 0.5;
    return clamp(spatial, temporal - allowance, temporal + allowance);
}

kernel void convertFrame(texture2d<float, access::read> luma [[texture(0)]],
                         texture2d<float, access::read> chroma [[texture(1)]],
                         texture2d<float, access::write> output [[texture(2)]],
                         texture2d<float, access::read> previousLuma [[texture(3)]],
                         texture2d<float, access::read> nextLuma [[texture(4)]],
                         constant ConvertParameters &parameters [[buffer(0)]],
                         uint2 position [[thread_position_in_grid]]) {
    uint width = luma.get_width();
    uint height = luma.get_height();
    if (position.x >= width || position.y >= height) {
        return;
    }
    uint chromaHeight = chroma.get_height();
    uint chromaX = min(position.x / 2, chroma.get_width() - 1);
    bool progressive = parameters.progressive != 0;

    if (parameters.mode == 0 || progressive) {
        // 織り込み: そのまま読む
        float y = luma.read(position).r;
        float2 c = chroma.read(uint2(chromaX, chromaRow(position.y, chromaHeight, progressive))).rg;
        output.write(float4(bt709(y, c), 1.0), position);
        return;
    }

    uint field = parameters.field;
    if (parameters.mode == 2) {
        bool missing = (position.y & 1) != field;
        float y = missing
            ? adaptiveLuma(luma, previousLuma, nextLuma, position.x, position.y, height, parameters.firstField != 0)
            : luma.read(position).r;
        // 色差は表示するフィールドの行を使う（色差の縦の解像度は輝度の半分なので、補っても差が小さい）
        uint fieldRow = missing ? (position.y == 0 ? 1 : position.y - 1) : position.y;
        float2 c = chroma.read(uint2(chromaX, chromaRow(fieldRow, chromaHeight, false))).rg;
        output.write(float4(bt709(y, c), 1.0), position);
        return;
    }

    // bob: 表示するフィールドの行だけを使い、間の行は上下の行から線形に補う
    float fieldPosition = (float(position.y) - float(field)) / 2.0;
    int lastIndex = int((height - 1 - field) / 2);
    int upper = clamp(int(floor(fieldPosition)), 0, lastIndex);
    int lower = clamp(upper + 1, 0, lastIndex);
    float weight = clamp(fieldPosition - float(upper), 0.0, 1.0);
    uint upperRow = uint(upper) * 2 + field;
    uint lowerRow = uint(lower) * 2 + field;
    float y = mix(luma.read(uint2(position.x, upperRow)).r, luma.read(uint2(position.x, lowerRow)).r, weight);
    float2 c = chroma.read(uint2(chromaX, chromaRow(upperRow, chromaHeight, false))).rg;
    output.write(float4(bt709(y, c), 1.0), position);
}

struct PresentVertexOut {
    float4 position [[position]];
    float2 texture;
};

// 画面いっぱいの四角形。scale で、表示のアスペクト比を保つよう縦横を縮める（上下・左右に黒帯）
vertex PresentVertexOut presentVertex(uint vertexID [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 corner = corners[vertexID];
    PresentVertexOut out;
    out.position = float4(corner * scale, 0, 1);
    out.texture = float2((corner.x + 1) / 2, (1 - corner.y) / 2);
    return out;
}

fragment float4 presentFragment(PresentVertexOut in [[stage_in]], texture2d<float> frame [[texture(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    return frame.sample(linearSampler, in.texture);
}
"""#
}
