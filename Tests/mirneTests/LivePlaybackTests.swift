import Foundation
import Testing

/// 読まれた回数を数える、終わらない受信
private final class CountingOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var count: Int { lock.withLock { reads } }

    var bytes: ByteChunks {
        ByteChunks { [self] in
            try await Task.sleep(for: .milliseconds(10))
            lock.withLock { reads += 1 }
            return Data(repeating: 0xFF, count: TSPacket.size)
        }
    }
}

@Suite("LivePlayback")
@MainActor
struct LivePlaybackTests {
    @Test("新しい TS を渡すと、前の TS は読まなくなる")
    func switchesToNewOutput() async throws {
        let playback = LivePlayback()
        let first = CountingOutput()
        let second = CountingOutput()
        playback.play(first.bytes, serviceID: nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(first.count > 0)

        playback.play(second.bytes, serviceID: 1024)
        try await Task.sleep(for: .milliseconds(150))
        let firstAfterSwitch = first.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(first.count == firstAfterSwitch)
        #expect(second.count > 0)
        #expect(playback.serviceID == 1024)

        await playback.stop()
        let secondAfterStop = second.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(second.count == secondAfterStop)
    }

    @Test("音量とミュートを出力へ渡す")
    func appliesVolumeAndMute() {
        let playback = LivePlayback()
        playback.volume = 0.25
        playback.isMuted = true
        #expect(playback.engine.volume == 0.25)
        #expect(playback.engine.isMuted)
        playback.volume = 3
        #expect(playback.volume == 1)
        #expect(playback.engine.volume == 1)
    }
}
