import CoreVideo
import Foundation
import Testing

/// 試験用のフレーム（29.97 fps の 1440×1080）
private func frame(pts: Int64) -> DecodedFrame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
    return DecodedFrame(pixelBuffer: buffer!, pts: pts,
                        sequence: MPEG2Sequence(width: 1440, height: 1080, aspectRatioCode: 3, frameRateCode: 4, progressiveSequence: false),
                        picture: MPEG2PictureInfo(codingType: .intra, temporalReference: 0))
}

/// 29.97 fps の 1 フレームと 1 フィールド（90 kHz）
private let frameDuration: Int64 = 3003
private let fieldDuration: Int64 = frameDuration / 2

@Suite("FrameQueue のフレームの選び方")
struct FrameQueueTests {
    private func queue(frames count: Int) -> FrameQueue {
        let queue = FrameQueue()
        for index in 0..<count {
            queue.push(frame(pts: Int64(index) * frameDuration))
        }
        return queue
    }

    @Test("時刻に合うフレームを出し、出したフレームを過ぎても捨てたと数えない")
    func showsFrameAtTime() {
        let queue = queue(frames: 4)
        #expect(queue.frame(at: 0)?.pts == 0)
        #expect(queue.frame(at: frameDuration + 10)?.pts == frameDuration)
        #expect(queue.lateDrops == 0)
    }

    @Test("一度も出していないフレームは、1 フィールド以内の遅れなら飛ばさずに出す")
    func showsUnshownFrameWithinGrace() {
        let queue = queue(frames: 4)
        #expect(queue.frame(at: 0)?.pts == 0)
        // 描画が 1 回ぶん遅れ、2 枚目の時刻を飛び越えて 3 枚目の頭に来た
        let late = 2 * frameDuration + fieldDuration - 1
        #expect(queue.frame(at: late)?.pts == frameDuration)
        #expect(queue.frame(at: late + 1500)?.pts == 2 * frameDuration)
        #expect(queue.lateDrops == 0)
    }

    @Test("1 フィールドより遅れたら、出していないフレームでも捨てて時刻に合うフレームを出す")
    func dropsUnshownFrameBeyondGrace() {
        let queue = queue(frames: 4)
        #expect(queue.frame(at: 0)?.pts == 0)
        #expect(queue.frame(at: 2 * frameDuration + fieldDuration)?.pts == 2 * frameDuration)
        #expect(queue.lateDrops == 1)
    }

    @Test("大きく遅れたときは、間のフレームをまとめて捨てる")
    func dropsSeveralFramesWhenFarBehind() {
        let queue = queue(frames: 6)
        #expect(queue.frame(at: 0)?.pts == 0)
        #expect(queue.frame(at: 4 * frameDuration)?.pts == 3 * frameDuration)
        #expect(queue.lateDrops == 2)
    }
}
