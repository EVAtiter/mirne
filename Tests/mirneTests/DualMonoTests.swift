import CoreMedia
import Foundation
import Testing

/// 試験用の二重音声。ffmpeg で 1 kHz（主）と 3 kHz（副）をモノラルの AAC にし、scripts/make-dual-mono.py で
/// 単一チャンネル要素 2 つの ADTS につなぎ直した 25 フレーム（約 0.5 秒）
private enum DualMonoSample {
    static let adts = Data(base64Encoded: [
        "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",
        "AEQszMrN7//D/t///+rl3L+363Hl/SSSV+PyHnnnnnnnnj+YjDzzzzzHnnnnnmPPPAGeeY88888888E1QAKRAAmAXMYCZ0gjCgAp",
        "P6f/5v/3f/j1uPm5fX/T2AMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDO9uuX9i+nd/iz3bv0n6T9J+khISEhN0JK3bt3Xr169es",
        "AUiA4P/xTIAYX/wBSDGRQt0Qh0Kj0Ij0KKqVus/t/t7S2l3Fuu+JcnEk0ABVoeHt2AAAAVfdL/H+D+n3Pl/g+f9D5f4i2/0H+IqM",
        "/+IqDe97C9a0Fb3sGtaCt72D/Gg+cD/Gg+eY/x8T57gDPDGSNlYWrWxbEBquH9fxpHxa7SSAAKtDw9uwAAFWh4e3YAADFof/z9Hw",
        "fyEEdDQkFY4PPdt23bcXAxueqc7uPC1sxI0NEUgjQcKRp2PqyygFXPPOVQKLsp+A//FMgBGf/AFCMYr6xSVVTfivu4aXpJHUWkkk",
        "A/x8GT7+8L+SCGb4+APf3AyfAGf3hHx8GGf3IP/ADvuAM0MYnwZh6tSKRl0NN5zrjiPqaSSSQH+PhtPv7wn+PhtPv7wn+PjM4KLL",
        "LJIXCSaaaEdaLNSyyRst0/RqZrJIRanHHFmR68MMJHE2xxxZgLg=",
    ].joined())!
    static let mainFrequency = 1000.0
    static let subFrequency = 3000.0
}

/// 復号した PCM のチャンネルごとの周波数（零交差から）
private func frequencies(_ buffers: [CMSampleBuffer]) -> [Double] {
    var channels: [[Float]] = []
    for buffer in buffers.dropFirst(5) {
        guard let block = CMSampleBufferGetDataBuffer(buffer),
              let format = CMSampleBufferGetFormatDescription(buffer),
              let count = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame else { continue }
        var pcm = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
        _ = pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        if channels.isEmpty { channels = Array(repeating: [], count: Int(count)) }
        for (index, value) in pcm.enumerated() { channels[index % Int(count)].append(value) }
    }
    return channels.map { values in
        let crossings = zip(values, values.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        return Double(crossings) / 2 / (Double(values.count) / 48_000)
    }
}

@Suite("二重音声")
struct DualMonoTests {
    @Test("単一チャンネル要素 2 つのフレームを二重音声と見分け、主・副・主+副を左右へ振り分ける")
    func decodesAndRoutes() {
        for (choice, expected) in [(DualMonoChannel.main, (DualMonoSample.mainFrequency, DualMonoSample.mainFrequency)),
                                   (.sub, (DualMonoSample.subFrequency, DualMonoSample.subFrequency)),
                                   (.both, (DualMonoSample.mainFrequency, DualMonoSample.subFrequency))] {
            let decoder = AACDecoder()
            let buffers = decoder.decode(DualMonoSample.adts, pts: 0, dualMono: choice)
            #expect(decoder.isDualMono)
            #expect(decoder.failures == 0)
            #expect(buffers.count == 25)
            let found = frequencies(buffers)
            #expect(found.count == 2)
            // 零交差での見積もりなので 5% の幅を見る
            #expect(abs(found[0] - expected.0) < expected.0 * 0.05, "\(choice) の左: \(found[0]) Hz")
            #expect(abs(found[1] - expected.1) < expected.1 * 0.05, "\(choice) の右: \(found[1]) Hz")
        }
    }

    @Test("生データブロックの最初の要素で見分ける（FIL は飛ばす）")
    func detectsFirstElement() {
        func starts(_ bytes: [UInt8]) -> Bool { bytes.withUnsafeBytes { AACRawDataBlock.startsWithSingleChannelElement($0) } }
        #expect(starts([0b000_0000_0, 0]))            // SCE
        #expect(!starts([0b001_0000_0, 0]))           // CPE（普通のステレオ）
        // FIL（長さ 1 バイト）の後に SCE
        #expect(starts([0b110_0001_0, 0b0000_0000, 0b0000_0000]))
        #expect(!starts([]))
    }

    @Test("前方に SCE を 2 つ置く PCE の AudioSpecificConfig（AAC-LC・48 kHz）")
    func audioSpecificConfig() {
        #expect(DualMonoConfiguration.audioSpecificConfig(objectType: 2, sampleRateIndex: 3)
            == [0x11, 0x80, 0x04, 0xC8, 0x00, 0x00, 0x00, 0x10, 0x00])
    }
}
