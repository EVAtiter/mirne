import Foundation

extension ProgramMap {
    /// 字幕の ES。ARIB では stream_type 0x06 で、component_tag 0x30〜0x37 が字幕（0x30 が既定の字幕）、
    /// 0x38〜0x3F が文字スーパー。文字スーパーは 1.0 では出さない
    public var caption: ElementaryStream? {
        let candidates = streams.filter {
            $0.streamType == ElementaryStream.privatePES && ($0.componentTag.map(CaptionStream.captionTags.contains) ?? false)
        }
        return candidates.first { $0.componentTag == CaptionStream.defaultCaptionTag } ?? candidates.first
    }
}

/// 字幕の ES の決まり（ARIB TR-B14）
enum CaptionStream {
    static let captionTags: ClosedRange<UInt8> = 0x30...0x37
    static let defaultCaptionTag: UInt8 = 0x30
    /// 消されないまま残る字幕の上限（消去の来ない壊れた入力で、溜まり続けないため）
    static let cueLimit = 256
}

/// 画面に出す字幕の文字の並び 1 つと、出す・消す時刻（90 kHz・再生の時計と同じ物差し）
public struct CaptionCue: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: CaptionText
    /// 字幕の画面の大きさ（`text` の位置はこの画面の画素）
    public let screenWidth: Int
    public let screenHeight: Int
    /// この並びが使う外字（DRCS）の図形（私用領域の文字ごと。大きさ違いの形が複数ありうる）
    public let drcs: [Unicode.Scalar: [CaptionDRCSGlyph]]
    public let showAt: Int64
    public var hideAt: Int64?

    func isVisible(at time: Int64) -> Bool {
        showAt <= time && hideAt.map { time < $0 } ?? true
    }
}

/// 字幕の本文を PTS の順に受け取り、ある時刻に画面に出ているものを答える。
///
/// 再生系（feed のタスク）が `apply` し、描く側（メインスレッド）が `visible` を読むので、lock で守る。
/// 本文の意味は `CaptionLayout` のとおり：CS があれば、それより前に出ていたものをその時刻に消す。
/// TIME で待ってからの CS は、その時刻に消す。文字ごとの待ち（delay）と消す時刻（until）は本文の PTS から数える
public final class CaptionTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [CaptionCue] = []
    private var nextID = 0
    /// 何度目の空にしたか（描く側が、前の再生の字幕を出し続けないように見分ける）
    private var generation = 0

    public init() {}

    /// 本文を 1 つ置いたものを、その PTS で足す
    public func apply(_ layout: CaptionLayout, at pts: Int64) {
        let ticksPerMillisecond: Int64 = 90
        lock.withLock {
            if layout.clear {
                for index in cues.indices { cues[index].hideAt = min(cues[index].hideAt ?? pts, pts) }
            }
            if let after = layout.clearAfter {
                let time = pts + Int64(after) * ticksPerMillisecond
                for index in cues.indices { cues[index].hideAt = min(cues[index].hideAt ?? time, time) }
            }
            for text in layout.texts {
                let showAt = pts + Int64(text.delay) * ticksPerMillisecond
                var hideAt = text.until.map { pts + Int64($0) * ticksPerMillisecond }
                if let after = layout.clearAfter { hideAt = min(hideAt ?? .max, pts + Int64(after) * ticksPerMillisecond) }
                var drcs: [Unicode.Scalar: [CaptionDRCSGlyph]] = [:]
                for scalar in text.text.unicodeScalars where CaptionDRCS.contains(scalar) {
                    drcs[scalar] = layout.drcs[scalar]
                }
                cues.append(CaptionCue(id: nextID, text: text, screenWidth: layout.screenWidth, screenHeight: layout.screenHeight,
                                       drcs: drcs, showAt: showAt, hideAt: hideAt))
                nextID += 1
            }
            if cues.count > CaptionStream.cueLimit { cues.removeFirst(cues.count - CaptionStream.cueLimit) }
        }
    }

    /// `time` に画面に出ているもの（足した順。後のものが上）。消えてしばらくたったものは捨てる
    public func visible(at time: Int64) -> [CaptionCue] {
        lock.withLock {
            cues.removeAll { cue in cue.hideAt.map { $0 <= time } ?? false }
            return cues.filter { $0.isVisible(at: time) }
        }
    }

    /// まだ出ていない（これから出す）ものも含めた数（試験・計測用）
    public var count: Int { lock.withLock { cues.count } }

    public var currentGeneration: Int { lock.withLock { generation } }

    /// すべて捨てる（選局し直す・時計を張り直す・サービスを切り替えるとき）
    public func reset() {
        lock.withLock {
            cues.removeAll()
            generation += 1
        }
    }
}
