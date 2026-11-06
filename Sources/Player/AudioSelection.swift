import Foundation

/// 音声のチャンネル構成（オーバーレイの表示用）。復号に使っている ADTS ヘッダから決める
public enum AudioLayout: Sendable, Equatable {
    case mono
    case stereo
    /// 二重音声（channel_configuration 2 に単一チャンネル要素が 2 つ）
    case dualMono
    /// 5.1ch（channel_configuration 6）
    case surround51
    /// そのほか（channel_configuration 3〜5・7、PCE で指定する 0）
    case other(channelConfiguration: Int)

    init(channelConfiguration: Int, dualMono: Bool) {
        switch channelConfiguration {
        case 1: self = .mono
        case 2: self = dualMono ? .dualMono : .stereo
        case 6: self = .surround51
        default: self = .other(channelConfiguration: channelConfiguration)
        }
    }
}

/// 番組の音声 ES の 1 本。PMT に書かれた順に並べる
public struct AudioTrack: Sendable, Hashable, Identifiable {
    public let pid: UInt16
    /// ストリーム識別記述子の component_tag（ARIB では 0x10 が既定の音声。無い送り手もある）
    public let componentTag: UInt8?

    public var id: UInt16 { pid }

    public init(pid: UInt16, componentTag: UInt8?) {
        self.pid = pid
        self.componentTag = componentTag
    }

    /// 選びたい音声に当たるものを、いまの PMT の音声から選ぶ。
    ///
    /// component_tag が合うもの → PID が合うもの → 先頭、の順。番組の境目で PMT が変わっても
    /// 同じ役割の音声（component_tag）を続け、選んだ音声が無くなったら先頭（既定の音声）に戻る
    static func resolve(_ preferred: AudioTrack?, in tracks: [AudioTrack]) -> AudioTrack? {
        guard let preferred else { return tracks.first }
        if let tag = preferred.componentTag, let byTag = tracks.first(where: { $0.componentTag == tag }) {
            return byTag
        }
        return tracks.first { $0.pid == preferred.pid } ?? tracks.first
    }
}

extension ProgramMap {
    /// 音声 ES（PMT に書かれた順）
    public var audioTracks: [AudioTrack] {
        audio.map { AudioTrack(pid: $0.pid, componentTag: $0.componentTag) }
    }
}

/// 「音声を切り替える」（A キー）で次に選ぶもの
public struct AudioChoice: Sendable, Equatable {
    public let track: AudioTrack
    public let dualMono: DualMonoChannel
}

/// いまの音声の状態（オーバーレイとメニューの表示用）
public struct AudioStatus: Sendable, Equatable {
    /// いまのサービスの音声 ES（PMT に書かれた順）
    public var tracks: [AudioTrack] = []
    /// 再生している音声 ES
    public var selected: AudioTrack?
    /// 再生している音声のチャンネル構成（まだ 1 フレームも復号していなければ nil）
    public var layout: AudioLayout?

    public init(tracks: [AudioTrack] = [], selected: AudioTrack? = nil, layout: AudioLayout? = nil) {
        self.tracks = tracks
        self.selected = selected
        self.layout = layout
    }

    /// 選んでいる音声が何本目か（0 から）
    public var selectedIndex: Int? { selected.flatMap { tracks.firstIndex(of: $0) } }

    /// 「音声を切り替える」で次に選ぶもの。選べるものが 1 つしかなければ nil。
    ///
    /// テレビのリモコンの音声切替と同じく、選択肢を 1 列に並べて順に回る。再生している音声が二重音声なら
    /// その ES は主・副・主+副の 3 つに分け、ほかの ES は 1 つずつ（二重音声かどうかは復号するまで分からない）。
    /// 別の ES へ移るときは二重音声を最初の選択（主）に戻す（移った先が二重音声なら、主から回り始める）
    public func nextChoice(after dualMono: DualMonoChannel) -> AudioChoice? {
        var choices: [AudioChoice] = []
        for track in tracks {
            if track == selected, layout == .dualMono {
                choices += DualMonoChannel.allCases.map { AudioChoice(track: track, dualMono: $0) }
            } else {
                choices.append(AudioChoice(track: track, dualMono: .initial))
            }
        }
        guard choices.count > 1 else { return nil }
        let current = choices.firstIndex { $0.track == selected && (layout != .dualMono || $0.dualMono == dualMono) } ?? 0
        return choices[(current + 1) % choices.count]
    }
}
