import AVFoundation
import CoreMedia
import Foundation
import os

/// 再生の時間の決まりごと。
///
/// 放送の TS では、映像は表示の時刻よりずっと早く（復号のバッファのぶん。局によって 1 秒を超える）届き、
/// 音声は表示の直前に届く。映像を届いたそばから復号して映像の時刻で時計を動かすと、音声がいつも時刻を過ぎて届き、
/// 出力で捨てられて音が出ない（実放送で局によって起きた。2026-11-04）。そこで映像は圧縮のまま溜め、
/// 時計は音声が揃う時刻から動かし、映像は時計の少し先までだけ復号する。
enum PlaybackTiming {
    /// 再生開始の時刻より先の音声を、これだけ出力に渡してから始める（90 kHz。0.2 秒）
    static let prerollAudio: Int64 = 18_000
    /// 映像の最初の I ピクチャが届いてから、これだけ待っても音声が 1 つも復号できなければ映像だけで始める。
    /// 音声を復号できない番組（チャンネル構成を PCE で指定した AAC など）で、映像まで止めないため
    static let audioWaitBeforeVideoOnly: Duration = .seconds(1)
    /// 音声は届いているのに、これだけ待っても始める時刻に追いつかなければ、追いつくのを待たずに始める（届き方が想定外の局で止まらないため）
    static let audioCatchUpLimit: Duration = .seconds(5)
    /// 時計よりこれだけ先の DTS まで映像を復号しておく（90 kHz。0.5 秒）。表示の順への並べ替えと描画の遅れを見込み、
    /// 復号済みのフレームを持つ `FrameQueue.capacity`（30 フレーム＝1 秒）に収まる量
    static let videoDecodeAhead: Int64 = 45_000
    /// 再生を始める前に圧縮のまま溜めておく映像の長さの上限（90 kHz。8 秒）。超えたら古い GOP から捨てる
    static let pendingVideoLimit: Int64 = 720_000
    /// PCR がこれ以上飛んだら不連続とみなして、時計を張り直す（90 kHz。1 秒）
    static let discontinuityThreshold: Int64 = 90_000
    /// 描いてから画面に出るまでの遅れの初期値（90 kHz。60 Hz の 1 回 = 1500）。
    /// 実際の遅れは VideoRenderer が画面に出た時刻から測って置き換える（実測では約 4 回ぶん・約 70 ms）
    static let initialPresentationDelay: Int64 = 1500
}

/// 再生の統計（計測用）
public struct PlaybackStatistics: Sendable {
    public var videoPES = 0
    public var audioFrames = 0
    public var audioFailures = 0
    public var discontinuities = 0
    public var starts = 0
    /// 再生開始までにかかった時間（最初のデータを受け取ってから）
    public var firstStartDelay: Duration?
    /// 直近のサービス切替から再生開始までにかかった時間
    public var lastSwitchDelay: Duration?
    public var switches = 0
    /// 受信している PCR と、いま表示している時刻の差（ミリ秒）。生放送からの遅れの目安
    public var latency: Double?
    /// いま再生している音声が二重音声か
    public var isDualMono = false
    /// 最後に出力へ渡した音声の時刻 − いまの時計（ミリ秒）。負なら音声が時計より遅れて届いていて、出力で捨てられている
    public var audioAhead: Double?
    /// 字幕のデータグループ（管理・本文）と、読めなかったもの・時刻に並べた本文
    public var captionGroups = 0
    public var captionUnreadable = 0
    public var captionStatements = 0
}

/// TS を受け取って、映像と音声を同じ時計で再生する。
///
/// 時計は AVSampleBufferRenderSynchronizer。音声は AVSampleBufferAudioRenderer がその時計で鳴らし、
/// 映像は VideoRenderer が描くたびに同じ時計を読んでフレームを選ぶ。
public final class PlayerEngine: @unchecked Sendable {
    public let frames = FrameQueue()
    /// 字幕を出す時刻の並び。描く側が時計の時刻で読む
    public let captions = CaptionTimeline()
    public let synchronizer = AVSampleBufferRenderSynchronizer()
    public let audioRenderer = AVSampleBufferAudioRenderer()

    private let demuxer = TSDemuxer()
    private var videoDecoder: MPEG2VideoDecoder!
    private let audioDecoder = AACDecoder()
    private var videoClock = TimestampUnwrapper()
    private var audioClock = TimestampUnwrapper()
    private var pcrClock = TimestampUnwrapper()
    private var captionClock = TimestampUnwrapper()
    /// 字幕を置く（feed の中でだけ触る）。字幕の ES が替わったら作り直す
    private var captionPresenter: CaptionPresenter?
    private var captionPID: UInt16? {
        didSet { lock.withLock { captionStreamPresent = captionPID != nil } }
    }
    /// `captionPID` があるか（lock で守る）
    private var captionStreamPresent = false
    private var lastPCR: Int64?
    private var lastAudioPTS: Int64?
    /// 今の時計で最初に復号できた音声の時刻（再生を始める時刻を決める）
    private var firstAudioPTS: Int64?
    /// 復号を待つ映像の PES（圧縮のまま。feed の中でだけ触る）
    private var pendingVideo: [PendingVideo] = []
    private var playing = false
    /// 音声が無いまま映像だけで始めた（後から届いた音声が時刻を過ぎていたら、時計を張り直して音声も鳴らす）
    private var startedWithoutAudio = false
    /// そのための張り直しをもうしたか（選局ごとに 1 回だけ。音声が途切れ途切れに届く局で張り直しを繰り返さないため）
    private var resyncedForAudio = false
    private var firstData: ContinuousClock.Instant?
    /// 映像の最初の I ピクチャが届いた時刻（音声を待ち始めた時刻）
    private var videoReadyAt: ContinuousClock.Instant?
    private var switchRequested: ContinuousClock.Instant?
    /// 次の feed で切り替えるサービス（外側の nil は「要求なし」、内側の nil は「既定のサービス」）
    private var pendingService: UInt16??
    private let lock = NSLock()
    private var selectedDualMono = DualMonoChannel.initial
    /// 選びたい音声 ES（nil なら先頭。どのスレッドからでも書く。lock で守る）。選局・サービスの切替で先頭に戻す
    private var preferredAudio: AudioTrack?
    /// いま再生している音声 ES（feed の中でだけ触る）
    private var activeAudio: AudioTrack?
    /// 再生している音声のチャンネル構成（feed の中で、復号できたら更新する。切り替えたら nil）
    private var audioLayout: AudioLayout?
    /// 最後にログへ残した音声の構成（feed の中でだけ触る。実放送の確認で、ステレオ ↔ 5.1・二重音声の境目を数える）
    private var loggedAudioLayout: AudioLayout?
    /// 最後に知らせた音声の状態（lock で守る）
    private var publishedAudio = AudioStatus()
    private var audioStatusHandler: (@Sendable (AudioStatus) -> Void)?
    private var enqueuedAudioHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private var decodedVideoHandler: (@Sendable (DecodedFrame) -> Void)?
    private var stats = PlaybackStatistics()
    private var epoch = 0
    private let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "player")
    /// 字幕の届き方の記録（実放送で字幕が遅れるときの切り分け用。本文の文字は出さない）
    private let captionLogger = Logger(subsystem: "com.slack-kingdom.mirne", category: "caption")

    public init() {
        synchronizer.addRenderer(audioRenderer)
        videoDecoder = MPEG2VideoDecoder { [weak self, frames] frame in
            frames.push(frame)
            self?.onVideoDecoded?(frame)
        }
    }

    /// 時計の今の時刻（90 kHz）。再生前は nil。描いた絵が画面に出るまでの遅れは描く側が足す
    public func presentationTime() -> Int64? {
        lock.lock()
        let isPlaying = playing
        lock.unlock()
        guard isPlaying else { return nil }
        let now = synchronizer.currentTime()
        guard now.isValid else { return nil }
        return Int64((now.seconds * 90_000).rounded())
    }

    /// ホスト時刻（CACurrentMediaTime の秒）のときの時計の時刻（90 kHz・先読みを含まない）
    public func mediaTime(atHost host: CFTimeInterval) -> Int64? {
        let hostTime = CMTime(seconds: host, preferredTimescale: 1_000_000_000)
        let converted = CMSyncConvertTime(hostTime, from: CMClockGetHostTimeClock(), to: synchronizer.timebase)
        guard converted.isValid else { return nil }
        return Int64((converted.seconds * 90_000).rounded())
    }

    public var statistics: PlaybackStatistics {
        lock.lock()
        defer { lock.unlock() }
        var copy = stats
        if playing, let lastPCR {
            copy.latency = Double(lastPCR - Int64(synchronizer.currentTime().seconds * 90_000)) / 90.0
        }
        if playing, let lastAudioPTS {
            copy.audioAhead = Double(lastAudioPTS - Int64(synchronizer.currentTime().seconds * 90_000)) / 90.0
        }
        copy.audioFailures = audioDecoder.failures
        return copy
    }

    public var decoder: MPEG2VideoDecoder { videoDecoder }

    /// 時計を動かし始めた・止めた回数。描画側が、描いた後に時計が変わったかを見分けるのに使う
    public var clockEpoch: Int {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    /// 音量（0〜1）
    public var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = min(max(newValue, 0), 1) }
    }

    /// ミュート
    public var isMuted: Bool {
        get { audioRenderer.isMuted }
        set { audioRenderer.isMuted = newValue }
    }

    /// 二重音声のどちらを出すか。次に復号する音声から効く（出力に渡し済みの約 0.2 秒は前のまま）
    public var dualMonoChannel: DualMonoChannel {
        get { lock.withLock { selectedDualMono } }
        set { lock.withLock { selectedDualMono = newValue } }
    }

    /// 音声の状態が変わったら呼ぶ（feed を呼んでいるタスクから呼ばれる）。オーバーレイとメニューの表示用
    public var onAudioStatus: (@Sendable (AudioStatus) -> Void)? {
        get { lock.withLock { audioStatusHandler } }
        set { lock.withLock { audioStatusHandler = newValue } }
    }

    /// 出力へ渡した音声（復号して二重音声を振り分けた後の PCM）を外へ渡す（feed を呼んでいるタスクから呼ばれる）。
    /// 二重音声の切替が、出力に渡す音声のどこから効いたかを測るのにも使う
    public var onAudioEnqueued: (@Sendable (CMSampleBuffer) -> Void)? {
        get { lock.withLock { enqueuedAudioHandler } }
        set { lock.withLock { enqueuedAudioHandler = newValue } }
    }

    /// 復号できた映像のフレームごとに呼ぶ（復号のスレッドから。復号の順なので、表示の順とは限らない）
    public var onVideoDecoded: (@Sendable (DecodedFrame) -> Void)? {
        get { lock.withLock { decodedVideoHandler } }
        set { lock.withLock { decodedVideoHandler = newValue } }
    }

    /// いまの音声の状態
    public var audioStatus: AudioStatus { lock.withLock { publishedAudio } }

    /// 音声 ES を選ぶ。どのスレッドから呼んでもよく、次の `feed` から効く。
    /// 番組の境目で PMT が変わっても同じ component_tag の音声を続ける。選局し直す・サービスを切り替えると先頭に戻す
    public func selectAudio(_ track: AudioTrack?) {
        lock.withLock { preferredAudio = track }
    }

    /// 受信した TS を渡す（同じタスクから順に呼ぶこと）
    public func feed(_ data: Data) {
        if firstData == nil { firstData = .now }
        applyPendingService()
        updateActiveAudio()
        for event in demuxer.feed(data) {
            switch event {
            case let .program(map):
                logger.info("PMT: 映像 \(map.video.map { String($0.pid) } ?? "-", privacy: .public)・音声 \(map.audio.count, privacy: .public) 本・字幕 \(map.caption.map { String($0.pid) } ?? "-", privacy: .public)")
                updateActiveAudio()
                if map.caption?.pid != captionPID {
                    resetCaptions()
                    captionPID = map.caption?.pid
                }
            case let .pcr(base, discontinuity):
                handlePCR(base, discontinuity: discontinuity)
            case let .pes(packet):
                handlePES(packet)
            }
        }
        startIfReady()
        decodePendingVideo()
        publishAudioStatus()
    }

    /// 同じ TS の中で別のサービスに切り替える（選局し直さない）。
    ///
    /// どのスレッドから呼んでもよい。次の `feed` の始めに切り替える（demux の状態は feed の中でしか触らない）。
    /// 切り替えでは時計を止めて空にし、新しいサービスの PMT・最初の I ピクチャを待って始め直す。
    public func requestService(_ serviceID: UInt16?) {
        lock.lock()
        pendingService = .some(serviceID)
        switchRequested = .now
        lock.unlock()
    }

    private func applyPendingService() {
        lock.lock()
        let request = pendingService
        pendingService = nil
        lock.unlock()
        guard case let .some(serviceID) = request else { return }
        restartClock(reason: "サービスを \(serviceID.map(String.init) ?? "既定") に切り替え")
        demuxer.select(serviceID: serviceID)
        // 別のサービスでは先頭（既定）の音声から始める
        activeAudio = nil
        captionPID = nil
        audioLayout = nil
        lock.withLock { preferredAudio = nil }
        lock.lock()
        stats.switches += 1
        stats.discontinuities -= 1  // 切替は不連続に数えない
        lock.unlock()
    }

    /// いまのサービスに字幕の ES があるか（描く側が読む）
    public var hasCaptionStream: Bool { lock.withLock { captionStreamPresent } }

    /// 今のサービス（PMT の番組番号）
    public var currentServiceID: UInt16? { demuxer.currentProgram?.programNumber }

    /// 再生を止めて、すべてを捨てる
    public func stop() {
        advanceEpoch()
        synchronizer.setRate(0, time: .zero)
        audioRenderer.flush()
        // 復号中のフレームを出し切らせてから空にする（逆だと、空にした後に前の時刻のフレームが入る）
        videoDecoder.reset()
        frames.removeAll()
        audioDecoder.reset()
        demuxer.reset()
        videoClock.reset()
        audioClock.reset()
        pcrClock.reset()
        resetCaptions()
        pendingVideo.removeAll()
        activeAudio = nil
        captionPID = nil
        audioLayout = nil
        lock.lock()
        preferredAudio = nil
        playing = false
        resyncedForAudio = false
        lastPCR = nil
        lastAudioPTS = nil
        firstAudioPTS = nil
        firstData = nil
        videoReadyAt = nil
        lock.unlock()
        publishAudioStatus()
    }

    // MARK: - 下請け

    /// 選びたい音声 ES を、いまの PMT の音声から決める。変わったら新しい ES から読み直す
    private func updateActiveAudio() {
        guard let program = demuxer.currentProgram else { return }
        let tracks = program.audioTracks
        let resolved = AudioTrack.resolve(lock.withLock { preferredAudio }, in: tracks)
        guard resolved != activeAudio else { return }
        let previous = activeAudio
        activeAudio = resolved
        guard let previous else { return }  // 最初の PMT（まだ何も読んでいない）
        // 前の ES の持ち越し（組み立て途中のフレーム）を捨てる
        audioDecoder.discardCarried()
        guard tracks.contains(previous) else {
            // 番組の境目などで PMT から前の ES が無くなった。出力に渡し済みの音声はそのまま鳴らす（切れ目を作らない）
            logger.info("PMT の音声が変わった: PID \(previous.pid, privacy: .public) → \(resolved.map { String($0.pid) } ?? "-", privacy: .public)")
            return
        }
        logger.info("音声を切り替える: PID \(previous.pid, privacy: .public) → \(resolved.map { String($0.pid) } ?? "-", privacy: .public)")
        // 利用者が選んだ切替。出力に渡し済みの前の ES の音声（約 0.2 秒）を捨てる。時計は止めない（映像はそのまま続き、
        // 新しい ES の音声は時計より少し先の時刻で届くので、届いたものから鳴る）
        audioLayout = nil
        audioRenderer.flush()
        lock.withLock {
            lastAudioPTS = nil
            // 再生前なら、始める時刻を新しい ES の音声で決め直す
            if !playing { firstAudioPTS = nil }
        }
    }

    /// 音声の状態が変わっていたら知らせる
    private func publishAudioStatus() {
        let status = AudioStatus(tracks: demuxer.currentProgram?.audioTracks ?? [], selected: activeAudio, layout: audioLayout)
        let handler: (@Sendable (AudioStatus) -> Void)? = lock.withLock {
            guard status != publishedAudio else { return nil }
            publishedAudio = status
            return audioStatusHandler
        }
        handler?(status)
    }

    private func handlePCR(_ base: Int64, discontinuity: Bool) {
        let value = pcrClock.unwrap(base)
        lock.lock()
        let previous = lastPCR
        lastPCR = value
        lock.unlock()
        if let previous, discontinuity || abs(value - previous) > PlaybackTiming.discontinuityThreshold {
            restartClock(reason: discontinuity ? "PCR の不連続の印" : "PCR が \(Double(value - previous) / 90_000) 秒飛んだ")
            // 張り直した後の最初の PCR として扱う
            pcrClock.reset()
            lock.lock()
            lastPCR = pcrClock.unwrap(base)
            lock.unlock()
        }
    }

    /// 時計の不連続: 再生を止め、復号器と出力を空にして、次のフレームから始め直す
    private func restartClock(reason: String) {
        logger.info("時計を張り直す: \(reason, privacy: .public)")
        advanceEpoch()
        synchronizer.setRate(0, time: .zero)
        audioRenderer.flush()
        // 復号中のフレームを出し切らせてから空にする（逆だと、空にした後に前の時刻のフレームが入る）
        videoDecoder.reset()
        frames.removeAll()
        audioDecoder.reset()
        videoClock.reset()
        audioClock.reset()
        resetCaptions()
        pendingVideo.removeAll()
        lock.lock()
        playing = false
        lastAudioPTS = nil
        firstAudioPTS = nil
        videoReadyAt = nil
        stats.discontinuities += 1
        lock.unlock()
    }

    private func handlePES(_ packet: PESPacket) {
        guard let program = demuxer.currentProgram else { return }
        if packet.pid == program.video?.pid {
            guard let pts = packet.pts else { return }
            lock.lock()
            stats.videoPES += 1
            lock.unlock()
            // 圧縮のまま溜め、時計が近づいてから復号する（decodePendingVideo）
            let unwrapped = videoClock.unwrap(pts)
            let scanned = MPEG2Parser.scan(packet.payload)
            pendingVideo.append(PendingVideo(payload: packet.payload, pts: unwrapped,
                                             dts: packet.dts.map { videoClock.unwrap($0) } ?? unwrapped, damaged: packet.damaged,
                                             isRandomAccess: scanned.sequence != nil && scanned.picture?.codingType == .intra))
            trimPendingVideo()
        } else if packet.pid == captionPID {
            handleCaption(packet)
        } else if packet.pid == activeAudio?.pid {
            guard !packet.damaged else {
                // 欠けた PES とつなぐと偽のフレームを作るので、持ち越しを捨てて次の PES から読み直す
                audioDecoder.discardCarried()
                return
            }
            let dualMono = dualMonoChannel
            let samples = audioDecoder.decode(packet.payload, pts: packet.pts.map { audioClock.unwrap($0) }, dualMono: dualMono)
            if let first = samples.first, lock.withLock({ playing && startedWithoutAudio }) {
                let now = synchronizer.currentTime()
                if first.presentationTimeStamp < now, !lock.withLock({ resyncedForAudio }) {
                    // 映像だけで始めた時計が音声より先へ進んでいて、このまま渡しても時刻を過ぎていて鳴らない
                    lock.withLock { resyncedForAudio = true }
                    restartClock(reason: "映像だけで始めた後に届いた音声が時刻を過ぎていた")
                    return
                }
                lock.withLock { startedWithoutAudio = false }
            }
            if !samples.isEmpty {
                audioLayout = audioDecoder.layout
                if let layout = audioLayout, layout != loggedAudioLayout {
                    logger.notice("音声の構成: \(self.loggedAudioLayout.map { String(describing: $0) } ?? "-", privacy: .public) → \(String(describing: layout), privacy: .public)")
                    loggedAudioLayout = layout
                }
            }
            let enqueued = onAudioEnqueued
            for sample in samples {
                audioRenderer.enqueue(sample)
                enqueued?(sample)
                lock.lock()
                stats.audioFrames += 1
                stats.isDualMono = audioDecoder.isDualMono
                lastAudioPTS = Int64(sample.presentationTimeStamp.seconds * 90_000)
                if firstAudioPTS == nil { firstAudioPTS = lastAudioPTS }
                lock.unlock()
            }
        }
    }

    /// 字幕の PES を読んで置き、PTS で並べる。第 1 言語だけ。
    /// PTS の無い PES（非同期 PES）は、届いた時点の時計の時刻に出す
    private func handleCaption(_ packet: PESPacket) {
        lock.withLock { stats.captionGroups += 1 }
        guard !packet.damaged, let group = CaptionDecoder.parsePES(packet.payload) else {
            lock.withLock { stats.captionUnreadable += 1 }
            captionLogger.info("字幕の PES: \(packet.damaged ? "欠けている" : "読めない", privacy: .public)・\(packet.payload.count, privacy: .public) バイト")
            return
        }
        let presenter = captionPresenter ?? CaptionPresenter(kind: group.kind)
        captionPresenter = presenter
        if let management = group.management {
            presenter.manage(management)
            captionLogger.info("字幕の PES: 管理データ・言語 \(management.languages.count, privacy: .public) つ")
            return
        }
        guard let statement = group.statement, group.language == presenter.language else {
            captionLogger.info("字幕の PES: 本文を使わない（\(group.statement == nil ? "本文が無い" : "第 \(group.language.map(String.init) ?? "-") 言語", privacy: .public)）")
            return
        }
        let layout = presenter.present(statement)
        let now = presentationTime()
        guard let time = packet.pts.map({ captionClock.unwrap($0) }) ?? now else { return }
        captions.apply(layout, at: time)
        // 届いた時点で、出すべき時刻までどれだけ余裕があったか（負なら届いた時にはもう過ぎていて、その分遅れて出る）
        let margin = now.map { String(format: "%+.0f ms", Double(time - $0) / 90) } ?? "-（再生前）"
        let delays = layout.texts.map(\.delay).filter { $0 > 0 }
        captionLogger.info("字幕の本文: PTS \(packet.pts == nil ? "なし（届いた時に出す）" : "あり", privacy: .public)・届いた時点の余裕 \(margin, privacy: .public)・並び \(layout.texts.count, privacy: .public)・文字 \(layout.texts.reduce(0) { $0 + $1.text.unicodeScalars.count }, privacy: .public)・CS \(layout.clear ? "あり" : "なし", privacy: .public)・待ち \(delays.isEmpty ? "なし" : delays.map { "\($0) ms" }.joined(separator: " "), privacy: .public)")
        lock.withLock { stats.captionStatements += 1 }
    }

    /// 字幕を空にし、置く状態を捨てる（次の管理データで画面を整え直す）
    private func resetCaptions() {
        captions.reset()
        captionPresenter = nil
        captionClock.reset()
    }

    /// 音声の PES とフレームの組み立ての数（診断用。この再生系を作ってからの累計）
    public var audioFramingSummary: String {
        let decoder = audioDecoder
        return "PES \(decoder.pesCount)（PTS なし \(decoder.pesWithoutPTS)・頭が同期語でない \(decoder.pesNotStartingWithSync)）・"
            + "PES をまたいだフレーム \(decoder.framesAcrossPES)・読み飛ばし \(decoder.skippedBytes) バイト・時刻不明で捨てた \(decoder.untimedFrames)・"
            + "復号 \(decoder.decodedFrames)・失敗 \(decoder.failures)"
    }

    /// 再生中なら、時計より `videoDecodeAhead` 先の DTS までの映像を復号する
    private func decodePendingVideo() {
        guard lock.withLock({ playing }), !pendingVideo.isEmpty else { return }
        let now = Int64((synchronizer.currentTime().seconds * 90_000).rounded())
        var decoded = 0
        for item in pendingVideo {
            guard item.dts <= now + PlaybackTiming.videoDecodeAhead else { break }
            videoDecoder.decode(item.payload, pts: item.pts, dts: item.dts, damaged: item.damaged)
            decoded += 1
        }
        if decoded > 0 { pendingVideo.removeFirst(decoded) }
    }

    /// 再生を始める前に溜めすぎないよう、上限を超えたら古い GOP（次の I ピクチャの手前まで）を捨てる
    private func trimPendingVideo() {
        guard !lock.withLock({ playing }) else { return }
        while let first = pendingVideo.first, let last = pendingVideo.last, last.dts - first.dts > PlaybackTiming.pendingVideoLimit {
            let next = pendingVideo.dropFirst().firstIndex(where: \.isRandomAccess) ?? pendingVideo.count
            pendingVideo.removeFirst(next)
        }
    }

    /// 時計を変える前に呼ぶ（描画側が、変わる前に描いた絵を新しい時計で測らないように）
    private func advanceEpoch() {
        lock.lock()
        epoch += 1
        lock.unlock()
    }

    /// 映像の I ピクチャと、その時刻より先の音声が揃ったら、時計を動かす。
    ///
    /// 始める時刻は「音声の最初の時刻」と「映像の最初の I ピクチャ（シーケンスヘッダ付き）の時刻」の遅いほう。
    /// 音声がその時刻より `prerollAudio` 先まで届いたら始める。音声が 1 つも復号できないまま待ちすぎたら映像だけで始める
    private func startIfReady() {
        lock.lock()
        let alreadyPlaying = playing
        let audioEnd = lastAudioPTS
        let audioStart = firstAudioPTS
        lock.unlock()
        guard !alreadyPlaying, let firstAccess = pendingVideo.first(where: \.isRandomAccess) else { return }
        let now = ContinuousClock.now
        let readySince = lock.withLock {
            if videoReadyAt == nil { videoReadyAt = now }
            return videoReadyAt!
        }
        let waited = now - readySince
        let hasAudio = !(demuxer.currentProgram?.audio.isEmpty ?? true)
        var start = firstAccess.pts
        if hasAudio {
            if let audioStart {
                start = max(audioStart, firstAccess.pts)
                if !(audioEnd.map { $0 >= start + PlaybackTiming.prerollAudio } ?? false) {
                    guard waited >= PlaybackTiming.audioCatchUpLimit else { return }
                    logger.notice("音声が始める時刻に追いつかないので、待たずに始める")
                }
            } else {
                guard waited >= PlaybackTiming.audioWaitBeforeVideoOnly else { return }
                logger.notice("音声が揃わないので映像だけで始める（音声の失敗 \(self.audioDecoder.failures, privacy: .public)）")
            }
        }
        let withoutAudio = hasAudio && audioStart == nil
        // 始める時刻より前の、最後の I ピクチャから復号する（それより前の映像は表示しないので捨てる）
        if let from = pendingVideo.lastIndex(where: { $0.isRandomAccess && $0.pts <= start }) {
            pendingVideo.removeFirst(from)
        }
        // 始めたときの映像・音声の届き方（PCR からどれだけ先の時刻まで届いているか。ミリ秒）
        let (pcr, audio) = lock.withLock { (lastPCR, lastAudioPTS) }
        let lead: (Int64?) -> String = { pts in
            guard let pts, let pcr else { return "-" }
            return String(format: "%.0f", Double(pts - pcr) / 90)
        }
        let videoEnd = pendingVideo.last?.pts
        logger.notice("再生開始: 始める時刻 \(lead(start), privacy: .public) ms・映像の末尾 \(lead(videoEnd), privacy: .public) ms・音声の末尾 \(lead(audio), privacy: .public) ms（PCR から）・待った \(waited.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        logger.notice("音声の組み立て: \(self.audioFramingSummary, privacy: .public)")
        advanceEpoch()
        synchronizer.setRate(1, time: CMTime(value: start, timescale: 90_000))
        lock.lock()
        playing = true
        startedWithoutAudio = withoutAudio
        stats.starts += 1
        if stats.firstStartDelay == nil, let firstData {
            stats.firstStartDelay = .now - firstData
        }
        if let switchRequested {
            stats.lastSwitchDelay = .now - switchRequested
            self.switchRequested = nil
        }
        lock.unlock()
        logger.info("再生を始めた（\(Double(start) / 90_000, privacy: .public) 秒）")
    }
}

/// TS ファイルを、PCR の進みに合わせた速さで読み出す（生放送の代わり。検証用）。
///
/// PCR が飛んだら、そこを新しい起点にする（つないだファイルでも止まらない）。
public struct TSFileSource: Sendable {
    /// 1 回に読む量（約 18 Mbps で 30 ms 程度）
    static let chunkSize = 188 * 360

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// 最後まで読んだら終わる。`deliver` はデータを受け取るたびに呼ばれる
    public func run(deliver: @Sendable (Data) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pcrPID: UInt16?
        var origin: (pcr: Int64, wall: ContinuousClock.Instant)?
        var lastPCR: Int64?
        while let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty {
            try Task.checkCancellation()
            // 塊の中の最後の PCR まで待つ
            var newest: Int64?
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset + TSPacket.size <= bytes.count {
                    defer { offset += TSPacket.size }
                    guard bytes[offset] == TSPacket.syncByte, bytes[offset + 3] & 0x20 != 0, bytes[offset + 4] >= 7,
                          bytes[offset + 5] & 0x10 != 0 else { continue }
                    let pid = UInt16(bytes[offset + 1] & 0x1F) << 8 | UInt16(bytes[offset + 2])
                    if pcrPID == nil { pcrPID = pid }
                    guard pid == pcrPID else { continue }
                    newest = Int64(bytes[offset + 6]) << 25 | Int64(bytes[offset + 7]) << 17 | Int64(bytes[offset + 8]) << 9
                        | Int64(bytes[offset + 9]) << 1 | Int64(bytes[offset + 10]) >> 7
                }
            }
            if let pcr = newest {
                if let last = lastPCR, abs(pcr - last) > PlaybackTiming.discontinuityThreshold {
                    origin = nil
                }
                lastPCR = pcr
                if let origin {
                    let due = origin.wall + .microseconds((pcr - origin.pcr) * 1_000_000 / 90_000)
                    if due > .now { try await Task.sleep(until: due) }
                } else {
                    origin = (pcr, .now)
                }
            }
            deliver(data)
        }
    }
}

/// 復号を待つ映像の PES（圧縮のまま）
private struct PendingVideo {
    let payload: Data
    let pts: Int64
    let dts: Int64
    let damaged: Bool
    /// シーケンスヘッダ付きの I ピクチャ（ここから復号を始められる）
    let isRandomAccess: Bool
}
