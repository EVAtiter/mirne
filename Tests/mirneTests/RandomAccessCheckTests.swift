import Foundation
import Testing

// 始められる絵の判定（`MPEG2Parser.isRandomAccess`）は、PES の頭だけ読む形にした
// （2026-11-21。CPU の使い道を測って見つけた）。全体を走査する `scan` での判定と、いつも同じ結果になることを確かめる

/// 決まった並びを返す乱数（試験を流すたびに同じ PES を作る）
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

struct RandomAccessCheckTests {
    /// MPEG-2 の部品（開始符号から）
    private static func mpeg2Pieces(_ random: inout SeededGenerator) -> [UInt8] {
        let filler = (0..<Int.random(in: 0...6, using: &random)).map { _ in UInt8.random(in: 1...255, using: &random) }
        switch Int.random(in: 0..<6, using: &random) {
        case 0: return [0, 0, 1, 0xB3, 0x5A, 0x04, 0x38, 0x34] + filler        // シーケンスヘッダ
        case 1: return [0, 0, 1, 0xB5, 0x14, 0x82, 0x00, 0x01] + filler        // シーケンス拡張
        case 2: return [0, 0, 1, 0xB8, 0x00, 0x08, 0x00] + filler              // GOP
        case 3:
            let type = UInt8.random(in: 0...4, using: &random)                   // 0・4 は知らない種類
            return [0, 0, 1, 0x00, 0x01, type << 3] + filler                     // ピクチャヘッダ
        case 4: return [0, 0, 1, UInt8.random(in: 0x01...0xAF, using: &random)] + filler  // スライス
        default: return filler + [0]                                             // 開始符号でない並び
        }
    }

    @Test("MPEG-2：頭だけ読む判定は、全体を走査した判定と同じ（乱数で 5,000 通り）")
    func mpeg2MatchesScan() {
        var random = SeededGenerator(state: 0x2026_1121)
        var outcomes = Set<Bool>()
        for _ in 0..<5_000 {
            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 0...8, using: &random) { bytes += Self.mpeg2Pieces(&random) }
            let data = Data(bytes)
            let scanned = MPEG2Parser.scan(data)
            let expected = scanned.sequence != nil && scanned.picture?.codingType == .intra
            #expect(MPEG2Parser.isRandomAccess(data) == expected, "\(bytes)")
            outcomes.insert(expected)
        }
        #expect(outcomes == [true, false])   // 真も偽も試せていること
    }
}
