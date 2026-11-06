import Foundation
import Testing

@Suite("音声 ES の選択と切替")
struct AudioSelectionTests {
    private let main = AudioTrack(pid: 0x111, componentTag: 0x10)
    private let second = AudioTrack(pid: 0x112, componentTag: 0x11)

    @Test("選びたい音声は component_tag → PID → 先頭 の順で決める")
    func resolvesPreferredTrack() {
        let tracks = [main, second]
        #expect(AudioTrack.resolve(nil, in: tracks) == main)
        #expect(AudioTrack.resolve(second, in: tracks) == second)
        // 番組の境目で PID が変わっても、同じ component_tag の音声を続ける
        let moved = AudioTrack(pid: 0x122, componentTag: 0x11)
        #expect(AudioTrack.resolve(second, in: [main, moved]) == moved)
        // component_tag の無い送り手では PID で選ぶ
        let untagged = [AudioTrack(pid: 0x101, componentTag: nil), AudioTrack(pid: 0x102, componentTag: nil)]
        #expect(AudioTrack.resolve(untagged[1], in: untagged) == untagged[1])
        // 選んだ音声が無くなったら先頭（既定の音声）へ戻る
        #expect(AudioTrack.resolve(second, in: [main]) == main)
        #expect(AudioTrack.resolve(second, in: []) == nil)
    }

    @Test("音声 ES が 2 本なら交互に回り、1 本のステレオなら切り替えるものが無い")
    func cyclesTracks() {
        let status = AudioStatus(tracks: [main, second], selected: main, layout: .stereo)
        #expect(status.nextChoice(after: .main) == AudioChoice(track: second, dualMono: .main))
        let onSecond = AudioStatus(tracks: [main, second], selected: second, layout: .surround51)
        #expect(onSecond.nextChoice(after: .main) == AudioChoice(track: main, dualMono: .main))
        #expect(AudioStatus(tracks: [main], selected: main, layout: .stereo).nextChoice(after: .main) == nil)
        #expect(AudioStatus().nextChoice(after: .main) == nil)
    }

    @Test("二重音声は主 → 副 → 主+副 → 主と回り、ほかの ES があればその後に移る")
    func cyclesDualMono() {
        let single = AudioStatus(tracks: [main], selected: main, layout: .dualMono)
        #expect(single.nextChoice(after: .main) == AudioChoice(track: main, dualMono: .sub))
        #expect(single.nextChoice(after: .sub) == AudioChoice(track: main, dualMono: .both))
        #expect(single.nextChoice(after: .both) == AudioChoice(track: main, dualMono: .main))

        let withSecond = AudioStatus(tracks: [main, second], selected: main, layout: .dualMono)
        #expect(withSecond.nextChoice(after: .sub) == AudioChoice(track: main, dualMono: .both))
        #expect(withSecond.nextChoice(after: .both) == AudioChoice(track: second, dualMono: .main))
    }

    @Test("チャンネル構成は channel_configuration と二重音声の見分けから決める")
    func layoutFromConfiguration() {
        #expect(AudioLayout(channelConfiguration: 1, dualMono: false) == .mono)
        #expect(AudioLayout(channelConfiguration: 2, dualMono: false) == .stereo)
        #expect(AudioLayout(channelConfiguration: 2, dualMono: true) == .dualMono)
        #expect(AudioLayout(channelConfiguration: 6, dualMono: false) == .surround51)
        #expect(AudioLayout(channelConfiguration: 0, dualMono: false) == .other(channelConfiguration: 0))
    }
}
