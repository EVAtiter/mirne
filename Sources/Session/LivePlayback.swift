import Foundation
import Observation

/// 受信した TS を `PlayerEngine` で再生する。
///
/// `Reception.onOutput` が渡す TS を 1 本ずつ再生する。選局し直して新しい TS が来たら、前の TS を読むのを
/// やめ（読み終わるのを待ってから）、エンジンを空にして始め直す。`PlayerEngine.feed` は同じタスクから
/// 順に呼ぶ決まりなので、読むのは常に 1 本のタスクだけにする。
///
/// 同じタスクで番組情報（EIT・TOT）も読み、`broadcast` へ渡す。
/// 受信した TS を読むのはこのタスクだけなので、ここで一緒に読む（別に読み手を立てると、TS を分けて配る仕組みが要る）。
@MainActor @Observable
public final class LivePlayback {
    public let engine: PlayerEngine
    /// 受信中の TS から読んだ番組情報
    public let broadcast = BroadcastInformation()

    /// 音量（0〜1。範囲の外は端にそろえる）。
    /// @Observable の didSet の中で自分に代入すると、もう一度 setter が呼ばれて止まらなくなるので、別の値に持つ
    public var volume: Float {
        get { storedVolume }
        set {
            storedVolume = min(max(newValue, 0), 1)
            engine.volume = storedVolume
        }
    }
    private var storedVolume: Float

    /// ミュート
    public var isMuted = false {
        didSet { engine.isMuted = isMuted }
    }

    /// 二重音声のどちらを出すか。局や番組が替わっても選んだものを続ける（二重音声でない番組では使わない）
    public var dualMonoChannel = DualMonoChannel.initial {
        didSet { engine.dualMonoChannel = dualMonoChannel }
    }

    /// 音声 ES とチャンネル構成。再生系が知らせるたびに更新する
    public private(set) var audio = AudioStatus()

    /// 再生するサービス（番組番号）。nil なら PAT の最初の番組
    public private(set) var serviceID: UInt16?

    @ObservationIgnored private var feeding: Task<Void, Never>?

    public init(engine: PlayerEngine = PlayerEngine()) {
        self.engine = engine
        storedVolume = engine.volume
        isMuted = engine.isMuted
        engine.onAudioStatus = { [weak self] status in
            Task { @MainActor in self?.audio = status }
        }
    }

    /// 音声 ES を選ぶ。選局し直す・サービスを切り替えると先頭に戻る。
    /// 再生系が切り替えて知らせるまでの間も続けて選べるよう、選んだものを先に反映する（チャンネル構成は復号するまで分からない）
    public func selectAudio(_ track: AudioTrack) {
        guard track != audio.selected else { return }
        engine.selectAudio(track)
        audio.selected = track
        audio.layout = nil
    }

    /// 新しい TS の再生を始める。前の TS はやめる
    public func play(_ output: ByteChunks, serviceID: UInt16?) {
        self.serviceID = serviceID
        let previous = feeding
        previous?.cancel()
        let broadcast = broadcast
        let generation = broadcast.begin()
        feeding = Task.detached { [engine] in
            // 前のタスクが feed を終えてから空にする（feed と stop を同時に走らせない）
            await previous?.value
            engine.stop()
            engine.requestService(serviceID)
            let reader = SIReader()
            do {
                for try await data in output {
                    if Task.isCancelled { break }
                    engine.feed(data)
                    let items = reader.feed(data)
                    if !items.isEmpty {
                        let receivedAt = Date()
                        Task { @MainActor in broadcast.apply(items, receivedAt: receivedAt, generation: generation) }
                    }
                }
            } catch {
                // 途切れたことは Reception が受け取って選局し直す。ここでは読むのをやめるだけ
            }
        }
    }

    /// 同じ TS の中で別のサービスに切り替える（選局し直さない）
    public func selectService(_ serviceID: UInt16?) {
        self.serviceID = serviceID
        engine.requestService(serviceID)
    }

    /// 再生をやめて空にする
    public func stop() async {
        let previous = feeding
        feeding = nil
        previous?.cancel()
        await previous?.value
        engine.stop()
    }
}
