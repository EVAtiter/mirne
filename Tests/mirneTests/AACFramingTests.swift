import CoreMedia
import Foundation
import Testing

/// 試験用の AAC。ffmpeg で 1 kHz をステレオの AAC（ADTS）にした 25 フレーム（約 0.5 秒）
private enum StereoSample {
    static let adts = Data(base64Encoded: [
        "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",
        "fPnXeffIjVJNw/rSSSAAAAAAAAABwA==",
    ].joined())!
}

@Suite("ADTS の組み立て（PES をまたぐフレーム）")
struct AACFramingTests {
    @Test("ADTS のフレームが PES をまたいでも、持ち越して全部を正しい時刻で復号する")
    func decodesFramesAcrossPES() {
        // 実放送では PES の頭が同期語で始まらない局があった。300 バイトずつに切って、PTS は持たせずに渡す
        // （最初の切れ端だけ PTS を持つ。それ以降は前のフレームから進めた時刻になる）
        let decoder = AACDecoder()
        let bytes = StereoSample.adts
        var buffers: [CMSampleBuffer] = []
        var offset = 0
        while offset < bytes.count {
            let piece = bytes.subdata(in: offset..<min(offset + 300, bytes.count))
            buffers += decoder.decode(piece, pts: offset == 0 ? 90_000 : nil)
            offset += 300
        }
        #expect(decoder.failures == 0)
        #expect(buffers.count == 25)
        #expect(decoder.framesAcrossPES > 0)
        // 1 フレームは 1024 サンプル（48 kHz）= 1920（90 kHz）
        let times = buffers.map { Int64($0.presentationTimeStamp.seconds * 90_000 + 0.5) }
        #expect(times == (0..<25).map { 90_000 + Int64($0) * 1920 })
    }

    @Test("頭が同期語でない PES は同期語を探し直し、時刻の分からないフレームは捨てる")
    func resynchronizes() {
        let decoder = AACDecoder()
        let bytes = StereoSample.adts
        // 受信の途中から: 最初のフレームの途中から始まる切れ端（PTS なし）、続きは PTS 付き
        let firstFrameLength = Int(bytes[3] & 0x03) << 11 | Int(bytes[4]) << 3 | Int(bytes[5]) >> 5
        let middle = 100
        let head = decoder.decode(bytes.subdata(in: middle..<firstFrameLength + 50), pts: nil)
        #expect(head.isEmpty)
        let rest = decoder.decode(bytes.subdata(in: (firstFrameLength + 50)..<bytes.count), pts: 180_000)
        #expect(decoder.failures == 0)
        #expect(decoder.skippedBytes > 0)
        // 2 フレーム目は、時刻の分からないまま始まった（PTS の付いた PES より前で始まる）ので捨て、3 フレーム目から
        #expect(decoder.untimedFrames == 1)
        #expect(rest.count == 23)
        #expect(rest.first.map { Int64($0.presentationTimeStamp.seconds * 90_000 + 0.5) } == 180_000)
    }
}
