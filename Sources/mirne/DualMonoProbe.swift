import CoreMedia
import Foundation

/// 二重音声の切替を、出力に渡した音声で確かめる（検証用）。
///
/// 生成素材 `dual-mono.ts` は主が 1 kHz・副が 440 Hz の正弦波（前後のステレオは左右とも 1 kHz）なので、
/// 出力へ渡した PCM の左右の周波数を零交差で数えれば、主・副・主+副のどれが出ているかが分かる
final class DualMonoProbe: @unchecked Sendable {
    /// 出力へ渡した音声 1 フレームの見立て
    struct Frame {
        /// PTS（90 kHz）
        let pts: Int64
        let left: Tone
        let right: Tone
    }

    /// 素材の音の高さの見分け
    enum Tone: String {
        case high = "1 kHz"
        case low = "440 Hz"
        case quiet = "ほぼ無音"
        case other = "?"

        /// 1 kHz と 440 Hz の間で分ける（どちらとも離れた値。素材を変えたらここも変える）
        static let boundaryHz = 700.0
        /// これより低ければ無音や雑音とみなす
        static let floorHz = 200.0
        /// 実効値がこれより小さければほぼ無音とみなす（素材の正弦波の実効値は 0.1 ほど。復号器を作り直した直後の立ち上がりを見分ける）
        static let quietRMS = 0.01

        init(hz: Double, rms: Double) {
            if rms < Self.quietRMS {
                self = .quiet
            } else {
                self = hz >= Self.boundaryHz ? .high : hz >= Self.floorHz ? .low : .other
            }
        }
    }

    private let lock = NSLock()
    private var frames: [Frame] = []

    /// 選んだものが出ているときの左右の音
    static func expected(_ channel: DualMonoChannel) -> (left: Tone, right: Tone) {
        switch channel {
        case .main: (.high, .high)
        case .sub: (.low, .low)
        case .both: (.high, .low)
        }
    }

    /// 出力へ渡した音声を記録する（feed のタスクから呼ばれる）
    func record(_ sample: CMSampleBuffer) {
        guard let description = sample.formatDescription,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mChannelsPerFrame == 2, let block = sample.dataBuffer else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return }
        let count = length / MemoryLayout<Float32>.size / 2
        guard count > 1 else { return }
        let seconds = Double(count) / format.mSampleRate
        let values = UnsafeRawPointer(pointer).bindMemory(to: Float32.self, capacity: count * 2)
        func hz(_ channel: Int) -> Double {
            var crossings = 0
            for index in 1..<count where (values[(index - 1) * 2 + channel] < 0) != (values[index * 2 + channel] < 0) {
                crossings += 1
            }
            return Double(crossings) / 2 / seconds
        }
        func rms(_ channel: Int) -> Double {
            var sum = 0.0
            for index in 0..<count { sum += Double(values[index * 2 + channel] * values[index * 2 + channel]) }
            return (sum / Double(count)).squareRoot()
        }
        let frame = Frame(pts: Int64((sample.presentationTimeStamp.seconds * 90_000).rounded()),
                          left: Tone(hz: hz(0), rms: rms(0)), right: Tone(hz: hz(1), rms: rms(1)))
        lock.withLock { frames.append(frame) }
    }

    /// 最後に出力へ渡したフレームの PTS
    var lastPTS: Int64? { lock.withLock { frames.last?.pts } }

    /// `pts` より後に出力へ渡したフレーム
    func frames(after pts: Int64) -> [Frame] {
        lock.withLock { frames.filter { $0.pts > pts } }
    }

    /// 出力へ渡した音声の移り変わり（同じ左右の音が続く区間ごと。PTS は最初のフレームからの秒）
    func segments() -> [String] {
        let all = lock.withLock { frames }
        guard let origin = all.first?.pts else { return [] }
        var result: [String] = []
        var start = 0
        for index in 1...all.count where index == all.count
            || all[index].left != all[start].left || all[index].right != all[start].right {
            result.append(String(format: "%.2f〜%.2f 秒 左 %@・右 %@（%d フレーム）",
                                 Double(all[start].pts - origin) / 90_000, Double(all[index - 1].pts - origin) / 90_000,
                                 all[start].left.rawValue, all[start].right.rawValue, index - start))
            start = index
        }
        return result
    }
}
