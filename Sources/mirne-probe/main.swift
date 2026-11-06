import CoreMedia
import CoreVideo
import Foundation

// mirne-probe: coaxd との接続・外部フィルタ・再生系を計測するためのコマンド。
//
//   mirne-probe [--coaxd <path>] version
//   mirne-probe [--coaxd <path>] tuners
//   mirne-probe [--coaxd <path>] stream --freq <Hz> [--seconds <秒>] [--out <file>]
//               [--filter "<シェルのコマンド>"] [--pcsc] [--throttle-mbps <Mbps>]
//   mirne-probe [--coaxd <path>] retune --freq <Hz> --freq <Hz> [--seconds <秒>] [--rounds <回>]
//   mirne-probe [--coaxd <path>] session --freq <Hz> [--freq <Hz> …] [--seconds <秒>]
//               TunerSession で順に選局し、状態の移り変わりを出す
//   mirne-probe [--coaxd <path>] epg --freq <Hz> [--seconds <秒>] [--filter "<シェルのコマンド>"] [--out <epg.sqlite>]
//               受信して LivePlayback で番組情報を読み、現在・次の番組・番組表の件数・放送時刻の差を出す。
//               --out を付けると番組表を EPGStore に保存する
//   mirne-probe guide --file <epg.sqlite>   保存した番組表のサービスごとの件数と範囲を出す
//   mirne-probe [--coaxd <path>] scan --out <フォルダー> [--cancel-after <秒>]
//               同梱の coax でスキャンし、一覧を channels.json に保存して並べて出す
//   mirne-probe channels --file <coax scan の JSON か channels.json>   一覧を並べて出す
//   mirne-probe demux --file <TS>      TS をほどいて PMT・PES・PCR を数える（coaxd は使わない）
//   mirne-probe decode --file <TS>     映像を VideoToolbox で復号し、出てくる順番と速さを見る
//   mirne-probe services (--file <TS> | --freq <Hz> [--seconds <秒>])  TS に含まれるサービスと PID を調べる
//   mirne-probe audio --file <TS> [--track <番号>]   音声を AACDecoder で復号し、チャンネルごとの音の高さ（零交差から）と振幅を出す。
//                                      二重音声なら主・副・主+副のそれぞれで出す。--track は PMT の順に 1 から（既定は 1 本目）
//   mirne-probe captions --file <TS>    字幕の ES を読んで置き、本文ごとに PTS・位置・文字を出す
//   mirne-probe captions --pes <ファイル>   字幕 PES の中身（1 行 1 つの 16 進）を CaptionDecoder で読んで置き、
//                                      mirne-si -captions と同じ書式で出す（coax との突き合わせ）
//   mirne-probe si --file <TS>         番組情報（EIT の番組名・概要）と時刻を 1 行 1 つの JSON で出す（mirne-si と同じ項目名）
// demux・decode には --service <番組番号> を付けられる（付けなければ PAT の最初の番組）
//
// --coaxd   デーモンが動いていなければその実行ファイルを起動する
// --filter  受信した TS をこのコマンド（/bin/sh -c で実行）の標準入力へ通し、標準出力を受け取る
// --pcsc    同じフォルダーの coax で `coax pcsc` を用意し、フィルタに PCSCLITE_CSOCK_NAME を渡す
// --throttle-mbps  受け取る側をこの速さに抑える（読み出しが遅いときの振る舞いを見る）

/// 計測の既定値。
enum ProbeDefaults {
    /// 1 本のストリームを受け取る秒数
    static let streamSeconds = 10.0
    /// retune で往復する回数
    static let retuneRounds = 3
}

struct ProbeArguments {
    var coaxd: String?
    var command = ""
    var frequencies: [Int] = []
    var seconds = ProbeDefaults.streamSeconds
    var rounds = ProbeDefaults.retuneRounds
    var output: String?
    var filter: String?
    var pcsc = false
    var throttleMbps: Double?
    var file: String?
    var service: UInt16?
    /// captions で読む字幕 PES の一覧（1 行 1 つの 16 進）
    var pes: String?
    /// audio で調べる音声 ES（PMT の順に 1 から）
    var track = 1
    /// scan をこの秒数で取り消す（取り消しの確認用）
    var cancelAfter: Double?

    init(_ arguments: [String]) throws {
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--coaxd": coaxd = rest.popFirst()
            case "--freq": if let value = rest.popFirst().flatMap({ Int($0) }) { frequencies.append(value) }
            case "--seconds": seconds = rest.popFirst().flatMap { Double($0) } ?? seconds
            case "--rounds": rounds = rest.popFirst().flatMap { Int($0) } ?? rounds
            case "--out": output = rest.popFirst()
            case "--filter": filter = rest.popFirst()
            case "--pcsc": pcsc = true
            case "--throttle-mbps": throttleMbps = rest.popFirst().flatMap { Double($0) }
            case "--file": file = rest.popFirst()
            case "--service": service = rest.popFirst().flatMap { UInt16($0) }
            case "--track": track = rest.popFirst().flatMap { Int($0) } ?? track
            case "--pes": pes = rest.popFirst()
            case "--cancel-after": cancelAfter = rest.popFirst().flatMap { Double($0) }
            default:
                guard command.isEmpty else { throw ProbeFailure("知らない引数: \(argument)") }
                command = argument
            }
        }
    }
}

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    var millisecondsText: String {
        String(format: "%.0f ms", seconds * 1000)
    }
}

/// 受け取る側の速さを抑える
struct Throttle {
    let bitsPerSecond: Double
    let started = ContinuousClock.now
    var bytes = 0

    mutating func pace(after count: Int) async {
        bytes += count
        let due = Double(bytes) * 8 / bitsPerSecond
        let elapsed = (ContinuousClock.now - started).seconds
        if due > elapsed {
            try? await Task.sleep(for: .milliseconds(Int((due - elapsed) * 1000)))
        }
    }
}

/// 受信の結果
struct ReceiveReport {
    var opened: Duration = .zero
    var firstByte: Duration?
    var bytesIn = 0
    var bytesOut = 0
    var input = TSPacketCounter()
    var output = TSPacketCounter()
    var verdict = DescrambleJudge.Verdict.undecided
    var tuner: CoaxTunerStatus?
    var filterStderr = ""
}

func connectClient(for arguments: ProbeArguments) async throws -> CoaxClient {
    let client = CoaxClient()
    print("ソケット: \(client.socketPath.utf8.count) バイト（上限 \(CoaxSocket.maxPathLength - 1)）")
    if let path = arguments.coaxd {
        let launcher = CoaxdLauncher(executable: URL(fileURLWithPath: path), client: client)
        let started = ContinuousClock.now
        let version = try await launcher.ensureRunning()
        print("coaxd \(version.version)（応答まで \((ContinuousClock.now - started).millisecondsText)）")
    }
    return client
}

/// 1 本のストリームを指定秒数だけ受け取る。フィルタがあれば通す
func receive(_ client: CoaxClient, frequency: Int, arguments: ProbeArguments,
             output: FileHandle? = nil) async throws -> ReceiveReport {
    var report = ReceiveReport()
    let clock = ContinuousClock()
    let requested = clock.now
    let limit = Duration.milliseconds(Int(arguments.seconds * 1000))

    // PC/SC のソケット（フィルタより先に用意する）
    var pcsc: CoaxPCSCSocket?
    if arguments.pcsc {
        guard let coaxd = arguments.coaxd else { throw ProbeFailure("--pcsc には --coaxd が要る（同じフォルダーの coax を使う）") }
        let coax = URL(fileURLWithPath: coaxd).deletingLastPathComponent().appendingPathComponent("coax")
        let started = clock.now
        pcsc = try await CoaxPCSCSocket.ensure(coax: coax, coaxdSocket: client.socketPath)
        print("PC/SC のソケット: \(pcsc!.path.utf8.count) バイト（用意まで \((clock.now - started).millisecondsText)）")
    }
    defer { pcsc?.release() }

    let stream = try await client.openStream(CoaxStreamRequest(frequency: frequency))
    report.opened = clock.now - requested

    var filter: ExternalFilter?
    if let command = arguments.filter {
        var environment: [String: String] = [:]
        if let pcsc { environment["PCSCLITE_CSOCK_NAME"] = pcsc.path }
        filter = try ExternalFilter.start(ExternalFilterCommand(executable: "/bin/sh", arguments: ["-c", command]),
                                          extraEnvironment: environment)
    }

    // 受信した TS（フィルタがあればその入力）を数える
    let inputCounter = CounterBox()
    let feeder: Task<Void, Error>? = filter.map { filter in
        Task {
            defer { filter.closeInput() }
            for try await data in stream.bytes {
                inputCounter.feed(data)
                try await filter.write(data)
            }
        }
    }

    let source: ByteChunks = filter?.output ?? stream.bytes
    var judge = DescrambleJudge()
    var throttle = arguments.throttleMbps.map { Throttle(bitsPerSecond: $0 * 1_000_000) }
    do {
        for try await data in source {
            let now = clock.now
            if report.firstByte == nil { report.firstByte = now - requested }
            if filter == nil { inputCounter.feed(data) }
            report.output.feed(data)
            report.bytesOut += data.count
            report.verdict = judge.observe(report.output, at: now)
            output?.write(data)
            await throttle?.pace(after: data.count)
            if now - requested >= limit { break }
        }
    } catch {
        print("受信が途中で終わった: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }

    // 閉じる前に coaxd の統計を取る（閉じるとストリーム統計が消える）
    if let id = stream.tunerID {
        report.tuner = try? await client.tunerStatus(id: id)
    }
    stream.close()
    feeder?.cancel()
    if let filter {
        await filter.terminate()
        report.filterStderr = filter.stderrText
    }
    report.input = inputCounter.value
    report.bytesIn = report.input.packets * TSPacket.size
    return report
}

/// フィルタへ渡すタスクと受け取る側で共有するカウンタ
final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = TSPacketCounter()

    func feed(_ data: Data) {
        lock.lock()
        counter.feed(data)
        lock.unlock()
    }

    var value: TSPacketCounter {
        lock.lock()
        defer { lock.unlock() }
        return counter
    }
}

func printReport(_ report: ReceiveReport, arguments: ProbeArguments) {
    let receiving = arguments.seconds - (report.firstByte?.seconds ?? 0)
    let rate = Double(report.bytesOut) * 8 / max(receiving, 1e-3) / 1_000_000
    print("応答ヘッダまで \(report.opened.millisecondsText)・最初のバイトまで \(report.firstByte?.millisecondsText ?? "-")")
    if arguments.filter != nil {
        print("フィルタの立ち上がり（応答ヘッダから最初の出力まで） \(report.firstByte.map { ($0 - report.opened).millisecondsText } ?? "-")")
        print("入力 \(report.input.packets) パケット（スクランブル \(report.input.scrambled)・不連続 \(report.input.discontinuities)）→ 出力 \(report.output.packets) パケット（スクランブル \(report.output.scrambled)・不連続 \(report.output.discontinuities)・同期外れ \(report.output.syncLosses)）")
    } else {
        print("受信 \(report.output.packets) パケット（スクランブル \(report.output.scrambled)・ヌル \(report.output.nulls)・不連続 \(report.output.discontinuities)・同期外れ \(report.output.syncLosses)）")
    }
    print("受け取り \(report.bytesOut) バイト・\(String(format: "%.2f", rate)) Mbps・判定 \(report.verdict)")
    if let tuner = report.tuner {
        let statistics = tuner.stream
        print("coaxd: C/N \(tuner.cnr.map { String(format: "%.1f dB", $0) } ?? "-")・捨てた \(tuner.dropped ?? 0)・不連続 \(statistics?.discontinuities ?? 0)・訂正不能 \(statistics?.errors ?? 0)・送出 \(statistics?.bytes ?? 0) バイト")
    }
    if !report.filterStderr.isEmpty {
        print("フィルタの標準エラー: \(report.filterStderr)")
    }
}

/// TS ファイルをほどいて数える
/// 最初の音声を AACDecoder で復号し、チャンネルごとに調べる（二重音声の確認）。二重音声だったかを返す
func audio(file path: String, dualMono: DualMonoChannel, track: Int) throws -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { throw ProbeFailure("開けない: \(path)") }
    let demuxer = TSDemuxer()
    let decoder = AACDecoder()
    var audioPID: UInt16?
    var samples: [[Float]] = []
    var channels = 0
    var sawDualMono = false
    while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
        for event in demuxer.feed(data) {
            switch event {
            case let .program(map):
                if audioPID == nil, map.audio.indices.contains(track - 1) { audioPID = map.audio[track - 1].pid }
            case let .pes(packet) where packet.pid == audioPID:
                let buffers = decoder.decode(packet.payload, pts: packet.pts, dualMono: dualMono)
                sawDualMono = sawDualMono || decoder.isDualMono
                for buffer in buffers {
                    guard let block = CMSampleBufferGetDataBuffer(buffer),
                          let format = CMSampleBufferGetFormatDescription(buffer),
                          let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
                    channels = Int(description.mChannelsPerFrame)
                    var pcm = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
                    _ = pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                    if samples.count < channels { samples = Array(repeating: [], count: channels) }
                    for (index, value) in pcm.enumerated() { samples[index % channels].append(value) }
                }
            default:
                continue
            }
        }
    }
    print("復号 \(decoder.decodedFrames) フレーム・失敗 \(decoder.failures)・\(channels) チャンネル"
          + (sawDualMono ? "・二重音声を含む（\(dualMono) を選んだ）" : ""))
    // 1・7・17 秒目から 0.1 秒ぶん（48 kHz）を調べる（dual-mono.ts はステレオ → 二重音声 → ステレオ）
    for second in [1, 7, 17] {
        let window = (second * 48_000)..<(second * 48_000 + 4_800)
        let found = samples.enumerated().filter { $0.element.count >= window.upperBound }.map { channel, values in
            let slice = values[window]
            let crossings = zip(slice, slice.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
            return String(format: "ch%d 約 %.0f Hz・振幅 %.3f", channel, Double(crossings) / 2 / 0.1, slice.map(abs).max() ?? 0)
        }
        if !found.isEmpty { print("  \(second) 秒: " + found.joined(separator: "　")) }
    }
    return sawDualMono
}

/// TS の字幕の ES を読んで置き、本文ごとに出す
func captions(file path: String) throws {
    guard let handle = FileHandle(forReadingAtPath: path) else { throw ProbeFailure("開けない: \(path)") }
    let demuxer = TSDemuxer()
    var captionPID: UInt16?
    let presenter = CaptionPresenter(kind: .caption)
    var groups = 0, statements = 0, unreadable = 0
    while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
        for event in demuxer.feed(data) {
            switch event {
            case let .program(map):
                captionPID = map.caption?.pid
            case let .pes(packet) where packet.pid == captionPID:
                groups += 1
                guard let group = CaptionDecoder.parsePES(packet.payload) else { unreadable += 1; continue }
                if let management = group.management {
                    presenter.manage(management)
                    continue
                }
                guard let statement = group.statement, group.language == 1 else { continue }
                statements += 1
                let layout = presenter.present(statement)
                let time = packet.pts.map { String(format: "%.3f", Double($0) / 90_000) } ?? "-"
                print("\(time) 秒\(layout.clear ? "・消去" : "")\(layout.clearAfter.map { "・\($0) ms 後に消去" } ?? "")・画面 \(layout.screenWidth)×\(layout.screenHeight)")
                for text in layout.texts {
                    print("  (\(text.x), \(text.y)) 升目 \(text.cellWidth)×\(text.cellHeight)・文字 \(text.glyphWidth)×\(text.glyphHeight)・色 \(text.foreground.r),\(text.foreground.g),\(text.foreground.b)"
                          + "\(text.delay > 0 ? "・\(text.delay) ms 待つ" : "")：\(text.text)")
                }
            default:
                continue
            }
        }
    }
    print("字幕の ES \(captionPID.map { String(format: "0x%04X", $0) } ?? "なし")・データグループ \(groups)・本文 \(statements)・読めない \(unreadable)")
}

/// 字幕 PES の一覧を読んで置き、1 行ずつ出す（mirne-si -captions と同じ書式）
func captions(pes path: String) throws {
    // 長さ 0 の PES は空の行になる。それも 1 件として数える（最後の改行の後ろだけを除く）
    var lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    let presenters: [CaptionKind: CaptionPresenter] = [.caption: CaptionPresenter(kind: .caption), .superimpose: CaptionPresenter(kind: .superimpose)]
    func color(_ c: CaptionColor) -> String { "\(c.r),\(c.g),\(c.b),\(c.a)" }
    var output = ""
    for (index, line) in lines.enumerated() {
        var bytes: [UInt8] = []
        var hex = line.trimmingCharacters(in: .whitespaces)[...]
        while hex.count >= 2 {
            guard let byte = UInt8(hex.prefix(2), radix: 16) else { throw ProbeFailure("16 進でない: \(index) 行目") }
            bytes.append(byte)
            hex = hex.dropFirst(2)
        }
        guard let group = CaptionDecoder.parsePES(bytes) else {
            output += "G \(index) -\n"
            continue
        }
        let kind = group.kind == .caption ? 0 : 1
        let presenter = presenters[group.kind]!
        if let management = group.management {
            let languages = management.languages.map {
                "\($0.tag):\($0.displayMode):\($0.languageCode):\($0.format):\($0.characterCoding):\($0.rollup)"
            }.joined(separator: ",")
            output += "G \(index) M kind=\(kind) id=\(group.id) tmd=\(management.timeMode) langs=\(languages) units=\(management.units.count)\n"
            presenter.manage(management)
            continue
        }
        guard let statement = group.statement else { continue }
        output += "G \(index) S kind=\(kind) id=\(group.id) tmd=\(statement.timeMode) stm=\(statement.presentationTime.map(String.init) ?? "-") units=\(statement.units.count)\n"
        let layout = presenter.present(statement)
        let motion = layout.motion.map { "\($0.fromX),\($0.fromY),\($0.toX),\($0.toY),\($0.delay),\($0.duration)" } ?? "-"
        output += "L screen=\(layout.screenWidth)x\(layout.screenHeight) area=\(layout.areaX),\(layout.areaY),\(layout.areaWidth),\(layout.areaHeight) "
            + "clear=\(layout.clear ? 1 : 0) after=\(layout.clearAfter.map(String.init) ?? "-") raster=\(color(layout.raster)) sound=\(layout.sound) motion=\(motion)\n"
        for text in layout.texts {
            let scalars = text.text.unicodeScalars.map { String($0.value, radix: 16, uppercase: true) }.joined(separator: " ")
            output += "T \(text.x),\(text.y) \(text.cellWidth),\(text.cellHeight) \(text.glyphWidth),\(text.glyphHeight) "
                + "fg=\(color(text.foreground)) bg=\(color(text.background)) ol=\(text.outline.map(color) ?? "-") "
                + "flash=\(text.flash) enc=\(text.enclosure) delay=\(text.delay) until=\(text.until.map(String.init) ?? "-") \(scalars)\n"
        }
        for scalar in layout.drcs.keys.sorted(by: { $0.value < $1.value }) {
            let glyphs = layout.drcs[scalar]!.map { glyph in
                "\(glyph.width)x\(glyph.height)/\(glyph.levels)/" + glyph.bitmap.map { String($0, radix: 16) }.joined()
            }.joined(separator: " ")
            output += "D \(String(scalar.value, radix: 16, uppercase: true)) \(glyphs)\n"
        }
    }
    FileHandle.standardOutput.write(Data(output.utf8))
}

func demux(file path: String, arguments: ProbeArguments) throws {
    guard let handle = FileHandle(forReadingAtPath: path) else { throw ProbeFailure("開けない: \(path)") }
    let demuxer = TSDemuxer()
    demuxer.select(serviceID: arguments.service)
    struct Tally { var count = 0; var damaged = 0; var bytes = 0; var firstPTS: Int64?; var lastPTS: Int64?; var withoutPTS = 0 }
    var tallies: [UInt16: Tally] = [:]
    var programs = 0
    var pcrCount = 0
    var pcrJumps = 0
    var lastPCR: Int64?
    let started = ContinuousClock.now
    while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
        for event in demuxer.feed(data) {
            switch event {
            case let .program(map):
                programs += 1
                let list = map.streams.map { String(format: "0x%04X(type 0x%02X)", $0.pid, $0.streamType) }.joined(separator: " ")
                print("PMT: 番組 \(map.programNumber)・版 \(map.version)・PCR 0x\(String(map.pcrPID, radix: 16)) ・\(list)")
            case let .pes(packet):
                var tally = tallies[packet.pid] ?? Tally()
                tally.count += 1
                tally.bytes += packet.payload.count
                if packet.damaged { tally.damaged += 1 }
                if let pts = packet.pts {
                    if tally.firstPTS == nil { tally.firstPTS = pts }
                    tally.lastPTS = pts
                } else {
                    tally.withoutPTS += 1
                }
                tallies[packet.pid] = tally
            case let .pcr(base, _):
                pcrCount += 1
                if let lastPCR, abs(base - lastPCR) > 90_000 { pcrJumps += 1 }
                lastPCR = base
            }
        }
    }
    let elapsed = ContinuousClock.now - started
    for (pid, tally) in tallies.sorted(by: { $0.key < $1.key }) {
        let span = zip([tally.firstPTS], [tally.lastPTS]).compactMap { first, last in
            first.flatMap { f in last.map { l in String(format: "%.2f〜%.2f 秒", Double(f) / 90_000, Double(l) / 90_000) } }
        }.first ?? "-"
        print(String(format: "PID 0x%04X", pid) + ": PES \(tally.count)・\(tally.bytes) バイト・PTS \(span)・PTS 無し \(tally.withoutPTS)・欠け \(tally.damaged)")
    }
    print("PMT \(programs) 回・PCR \(pcrCount) 回（1 秒以上の飛び \(pcrJumps)）・処理 \(elapsed.millisecondsText)")
}

/// 映像を復号して、出力の順番・数・速さを見る
func decode(file path: String, arguments: ProbeArguments) throws {
    guard let handle = FileHandle(forReadingAtPath: path) else { throw ProbeFailure("開けない: \(path)") }
    final class Outputs: @unchecked Sendable {
        let lock = NSLock()
        var frames: [(pts: Int64, width: Int, height: Int, format: OSType, type: MPEG2PictureInfo.CodingType, tff: Bool)] = []
    }
    let outputs = Outputs()
    let decoder = MPEG2VideoDecoder { frame in
        outputs.lock.lock()
        outputs.frames.append((frame.pts, CVPixelBufferGetWidth(frame.pixelBuffer), CVPixelBufferGetHeight(frame.pixelBuffer),
                               CVPixelBufferGetPixelFormatType(frame.pixelBuffer), frame.picture.codingType, frame.picture.topFieldFirst))
        outputs.lock.unlock()
    }
    let demuxer = TSDemuxer()
    demuxer.select(serviceID: arguments.service)
    var unwrapper = TimestampUnwrapper()
    var submitted = 0
    let started = ContinuousClock.now
    while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
        for case let .pes(packet) in demuxer.feed(data) where packet.pid == demuxer.currentProgram?.video?.pid {
            guard let pts = packet.pts else { continue }
            submitted += 1
            decoder.decode(packet.payload, pts: unwrapper.unwrap(pts), dts: packet.dts, damaged: packet.damaged)
        }
    }
    decoder.flush()
    let elapsed = ContinuousClock.now - started
    let frames = outputs.frames
    let order = frames.prefix(12).map { String(format: "%.3f", Double($0.pts) / 90_000) }.joined(separator: " ")
    let inversions = zip(frames, frames.dropFirst()).filter { $0.pts > $1.pts }.count
    let sizes = Set(frames.map { "\($0.width)×\($0.height)" }).sorted().joined(separator: "・")
    let formats = Set(frames.map { String(format: "%08X", $0.format) }).joined(separator: "・")
    print("PES \(submitted) → 出力 \(frames.count) フレーム（\(String(format: "%.0f", Double(frames.count) / elapsed.seconds)) fps）・大きさ \(sizes)・画素形式 \(formats)")
    print("捨てた: I より前 \(decoder.skippedBeforeIntra)・先頭の B \(decoder.skippedLeadingB)・欠けたまま復号 \(decoder.damagedPictures)・復号の失敗 \(decoder.decodeErrors)")
    print("出力の先頭 12 フレームの PTS（秒）: \(order)")
    print("PTS が前のフレームより小さい（表示順になっていない）箇所: \(inversions)")
}

/// サービスの一覧と PID を表示する
func printSurvey(_ survey: ServiceSurvey) {
    func type(_ value: UInt8) -> String {
        switch value {
        case ElementaryStream.mpeg2Video: "MPEG-2 映像"
        case ElementaryStream.aacADTS: "AAC"
        case ElementaryStream.h264: "H.264"
        case ElementaryStream.privatePES: "字幕など"
        case 0x0D: "データカルーセル"
        default: String(format: "type 0x%02X", value)
        }
    }
    for number in survey.programs.keys.sorted() {
        let pmt = survey.programs[number]!
        guard let map = survey.maps[number] else {
            print("サービス \(number): PMT 0x\(String(pmt, radix: 16)) は届いていない")
            continue
        }
        print("サービス \(number)（PMT 0x\(String(pmt, radix: 16))・版 \(map.version)・PCR 0x\(String(map.pcrPID, radix: 16))・ECM \(map.ecmPIDs.map { "0x" + String($0, radix: 16) }.joined(separator: ",")))")
        for stream in map.streams {
            let tag = stream.componentTag.map { String(format: "component_tag 0x%02X", $0) } ?? "-"
            let ecm = stream.ecmPID.map { "・ECM 0x" + String($0, radix: 16) } ?? ""
            print(String(format: "  0x%04X  ", stream.pid) + "\(type(stream.streamType))・\(tag)\(ecm)・\(survey.packetsPerPID[stream.pid] ?? 0) パケット")
        }
        let pids = ServicePIDs.pids(for: map, pmtPID: pmt)
        let present = pids.filter { (survey.packetsPerPID[$0] ?? 0) > 0 }
        print("  Mirakurun の規則で通す PID: \(pids.count) 個（うち実際に届いた \(present.count) 個）")
    }
    let fixed = ServicePIDs.fixedSI.keys.sorted().map { pid in
        "\(ServicePIDs.fixedSI[pid]!) \(survey.packetsPerPID[pid] ?? 0)"
    }.joined(separator: "・")
    print("固定の SI のパケット数: \(fixed)")
}

/// 番組情報を JSON Lines で出す（Go の mirne-si と同じ項目名。突き合わせ用）
func si(file path: String) throws {
    guard let handle = FileHandle(forReadingAtPath: path) else { throw ProbeFailure("開けない: \(path)") }
    let reader = SIReader()
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = SITables.japan
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    struct Line: Encodable {
        var kind: String
        var table_id: UInt8?
        var service_id: UInt16?
        var event_id: UInt16?
        var start: String?
        var duration_s: Int?
        var title_raw: String?
        var text_raw: String?
        var lossless: Bool?
        var time: String?
    }
    var output = Data()
    let started = ContinuousClock.now
    while let data = try handle.read(upToCount: 188 * 1024), !data.isEmpty {
        for item in reader.feed(data) {
            switch item {
            case let .eventSection(section):
                for event in section.events {
                    let line = Line(kind: "event", table_id: event.tableID, service_id: event.serviceID, event_id: event.eventID,
                                    start: event.start.map { formatter.string(from: $0) }, duration_s: event.duration,
                                    title_raw: event.title, text_raw: event.text, lossless: event.lossless)
                    output.append(try encoder.encode(line))
                    output.append(0x0A)
                }
            case let .time(time):
                output.append(try encoder.encode(Line(kind: "time", time: formatter.string(from: time))))
                output.append(0x0A)
            }
        }
    }
    FileHandle.standardOutput.write(output)
    FileHandle.standardError.write(Data("処理 \((ContinuousClock.now - started).millisecondsText)\n".utf8))
}

func run() async throws {
    let arguments = try ProbeArguments(Array(CommandLine.arguments.dropFirst()))
    if arguments.command == "jis-table" {
        // 2 バイトの全区点（追加記号の 0x75〜0x7E 区を含む）を、漢字の集合として復号した結果を「区点 文字」で出す（Go との突き合わせ用）
        var lines = ""
        for row in 0x21...0x7E {
            for cell in 0x21...0x7E {
                let result = ARIBStringDecoder.decode([0x1B, 0x24, 0x42, UInt8(row), UInt8(cell)])
                if result.lossless, !result.text.isEmpty { lines += String(format: "%02X%02X ", row, cell) + result.text + "\n" }
            }
        }
        FileHandle.standardOutput.write(Data(lines.utf8))
        return
    }
    if arguments.command == "si" {
        guard let file = arguments.file else { throw ProbeFailure("--file が要る") }
        return try si(file: file)
    }
    if arguments.command == "services", let file = arguments.file {
        guard let handle = FileHandle(forReadingAtPath: file) else { throw ProbeFailure("開けない: \(file)") }
        let survey = ServiceSurvey()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { survey.feed(data) }
        return printSurvey(survey)
    }
    if arguments.command == "decode" {
        guard let file = arguments.file else { throw ProbeFailure("--file が要る") }
        return try decode(file: file, arguments: arguments)
    }
    if arguments.command == "audio" {
        guard let file = arguments.file else { throw ProbeFailure("--file が要る") }
        for channel in DualMonoChannel.allCases {
            if try audio(file: file, dualMono: channel, track: arguments.track) == false { break }
        }
        return
    }
    if arguments.command == "captions" {
        if let file = arguments.file { return try captions(file: file) }
        guard let pes = arguments.pes else { throw ProbeFailure("--file か --pes が要る") }
        return try captions(pes: pes)
    }
    if arguments.command == "demux" {
        guard let file = arguments.file else { throw ProbeFailure("--file が要る") }
        return try demux(file: file, arguments: arguments)
    }
    if arguments.command == "session" {
        return try await session(arguments)
    }
    if arguments.command == "epg" {
        return try await epg(arguments)
    }
    if arguments.command == "guide" {
        guard let file = arguments.file else { throw ProbeFailure("--file が要る") }
        return printGuide(try EPGStore(fileURL: URL(fileURLWithPath: file)))
    }
    if arguments.command == "scan" {
        return try await scan(arguments)
    }
    if arguments.command == "channels" {
        guard let file = arguments.file else { throw ProbeFailure("--file が要る") }
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let list = try (try? ChannelStore(fileURL: URL(fileURLWithPath: file)).load()) ?? ChannelList.importing(scanResult: data)
        return printLineup(list)
    }
    let client = try await connectClient(for: arguments)

    switch arguments.command {
    case "version":
        let version = try await client.version()
        print("version=\(version.version) commit=\(version.commit ?? "-") started=\(version.started ?? "-") arch=\(version.arch ?? "-")")

    case "tuners":
        for device in try await client.devices() {
            print("\(device.name)  \(device.description)  open=\(device.open)")
            for tuner in device.tuners {
                print("  \(tuner.id)  \(tuner.deliveries.joined(separator: ","))  \(tuner.leased ? "使用中" : "空き")")
            }
        }

    case "stream":
        guard let frequency = arguments.frequencies.first else { throw ProbeFailure("--freq が要る") }
        var output: FileHandle?
        if let path = arguments.output {
            FileManager.default.createFile(atPath: path, contents: nil)
            output = FileHandle(forWritingAtPath: path)
        }
        let report = try await receive(client, frequency: frequency, arguments: arguments, output: output)
        try output?.close()
        printReport(report, arguments: arguments)

    case "services":
        guard let frequency = arguments.frequencies.first else { throw ProbeFailure("--freq か --file が要る") }
        let survey = ServiceSurvey()
        let stream = try await client.openStream(CoaxStreamRequest(frequency: frequency))
        let started = ContinuousClock.now
        let limit = Duration.milliseconds(Int(arguments.seconds * 1000))
        var completedAt: Duration?
        for try await data in stream.bytes {
            survey.feed(data)
            if completedAt == nil, survey.isComplete { completedAt = ContinuousClock.now - started }
            if ContinuousClock.now - started >= limit { break }
        }
        stream.close()
        print("PAT とすべての PMT が揃うまで \(completedAt?.millisecondsText ?? "-")（受信開始から）")
        printSurvey(survey)

    case "retune":
        guard arguments.frequencies.count >= 2 else { throw ProbeFailure("--freq を 2 つ指定する") }
        for round in 1...arguments.rounds {
            for frequency in arguments.frequencies {
                let report = try await receive(client, frequency: frequency, arguments: arguments)
                print("[\(round)] \(frequency) Hz: 応答ヘッダまで \(report.opened.millisecondsText)・最初のバイトまで \(report.firstByte?.millisecondsText ?? "-")・\(report.bytesOut) バイト")
            }
        }

    default:
        throw ProbeFailure("使い方: mirne-probe [--coaxd <path>] version|tuners|stream|retune …")
    }
}

/// Reception（TunerSession ＋ TS パイプライン）で選局し、状態の移り変わりと知らせを出す（実機での確認用）。
/// `--filter`・`--pcsc` はパイプラインの外部フィルタ、`--throttle-mbps` は読む側の速さ（遅れの見張りを試す）
/// 受信して番組情報を読む。番組情報はスクランブルされていないので、外部フィルタが無くても読める
@MainActor
func epg(_ arguments: ProbeArguments) async throws {
    guard let frequency = arguments.frequencies.first else { throw ProbeFailure("--freq が要る") }
    guard let executable = arguments.coaxd.map({ URL(fileURLWithPath: $0) }) ?? CoaxdLauncher.locate() else {
        throw ProbeFailure("--coaxd が要る")
    }
    let launcher = CoaxdLauncher(executable: executable)
    let filter = arguments.filter.map { ExternalFilterCommand(executable: "/bin/sh", arguments: ["-c", $0]) }
    let reception = Reception(tuner: TunerSession(service: CoaxTunerService(launcher: launcher)),
                              filterSettings: FilterSettings(command: filter, usesPCSC: arguments.pcsc))
    let playback = LivePlayback()
    playback.volume = 0
    let store = try arguments.output.map { try EPGStore(fileURL: URL(fileURLWithPath: $0)) }
    playback.broadcast.onSchedule = { sections, receivedAt in store?.save(sections, receivedAt: receivedAt) }
    reception.onOutput = { output in playback.play(output, serviceID: nil) }
    let started = ContinuousClock.now
    func say(_ text: String) {
        print(String(format: "%6.0f ms  ", (ContinuousClock.now - started).seconds * 1000) + text)
    }
    let formatter = DateFormatter()
    formatter.timeZone = SITables.japan
    formatter.dateFormat = "MM/dd HH:mm"
    func describe(_ event: BroadcastEvent?) -> String {
        guard let event else { return "-" }
        let start = event.start.map { formatter.string(from: $0) } ?? "未定"
        let end = event.end.map { formatter.string(from: $0) } ?? "未定"
        return "\(start)〜\(end) \(event.title)\(event.lossless ? "" : "（欠けあり）")"
    }
    reception.tune(TuningTarget(frequency: frequency))
    let broadcast = playback.broadcast
    var firstClock: Duration?
    var firstPresent: [UInt16: Duration] = [:]
    let limit = Duration.milliseconds(Int(arguments.seconds * 1000))
    while ContinuousClock.now - started < limit {
        let elapsed = ContinuousClock.now - started
        if firstClock == nil, let clock = broadcast.clock {
            firstClock = elapsed
            say(String(format: "放送の時刻が届いた（Mac の時計との差 %+.1f 秒）", clock.offset))
        }
        for (service, entry) in broadcast.presentFollowing where entry.present != nil && firstPresent[service] == nil {
            firstPresent[service] = elapsed
            say("サービス \(service) の現在の番組が届いた")
        }
        if case let .failed(_, failure) = reception.tuner.state {
            say("失敗: \(failure.title)。\(failure.advice)")
            break
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    for service in broadcast.presentFollowing.keys.sorted() {
        let entry = broadcast.presentFollowing[service]!
        print("サービス \(service)")
        print("  現在: \(describe(entry.present))")
        print("  次  : \(describe(entry.following))")
    }
    for service in broadcast.scheduledServices {
        let events = broadcast.schedule(of: service)
        let lossy = events.filter { !$0.lossless }.count
        print("番組表 サービス \(service): \(events.count) 件（\(describe(events.first).prefix(11))〜\(events.last?.end.map { formatter.string(from: $0) } ?? "-")・欠けあり \(lossy) 件）")
    }
    if let clock = broadcast.clock {
        print(String(format: "放送の時刻 − Mac の時刻: %+.1f 秒", clock.offset))
    }
    reception.stop()
    await playback.stop()
    if let store {
        store.flush()
        printGuide(store)
    }
}

/// 保存した番組表のサービスごとの件数と範囲
func printGuide(_ store: EPGStore) {
    let formatter = DateFormatter()
    formatter.timeZone = SITables.japan
    formatter.dateFormat = "MM/dd HH:mm:ss"
    for service in store.storedServices() {
        guard let coverage = store.coverage(networkID: service.networkID, transportStreamID: service.transportStreamID,
                                            serviceID: service.serviceID) else { continue }
        print("保存 サービス \(service.serviceID): \(coverage.eventCount) 件・\(coverage.latestEnd.map { formatter.string(from: $0) } ?? "-") まで・最後に受け取った \(formatter.string(from: coverage.lastReceived))")
    }
}

@MainActor
func session(_ arguments: ProbeArguments) async throws {
    guard !arguments.frequencies.isEmpty else { throw ProbeFailure("--freq が要る") }
    guard let executable = arguments.coaxd.map({ URL(fileURLWithPath: $0) }) ?? CoaxdLauncher.locate() else {
        throw ProbeFailure("--coaxd が要る")
    }
    let launcher = CoaxdLauncher(executable: executable)
    let tuner = TunerSession(service: CoaxTunerService(launcher: launcher))
    let coax = executable.deletingLastPathComponent().appendingPathComponent("coax")
    let filter = arguments.filter.map { ExternalFilterCommand(executable: "/bin/sh", arguments: ["-c", $0]) }
    let reception = Reception(tuner: tuner, filterSettings: FilterSettings(command: filter, usesPCSC: arguments.pcsc), coax: coax)
    let started = ContinuousClock.now
    func say(_ text: String) {
        print(String(format: "%6.0f ms  ", (ContinuousClock.now - started).seconds * 1000) + text)
    }
    func describe(_ state: TunerSession.State) -> String {
        switch state {
        case .idle: "停止"
        case let .tuning(target, attempt): "選局中 \(target.frequency) Hz（\(attempt) 回目）"
        case let .receiving(target, tunerID): "受信中 \(target.frequency) Hz（\(tunerID ?? "-")）"
        case let .failed(_, failure): "失敗: \(failure.title)。\(failure.advice)"
        }
    }
    let bytes = CounterBox()
    reception.onOutput = { output in
        let throttleMbps = arguments.throttleMbps
        Task.detached {
            var throttle = throttleMbps.map { Throttle(bitsPerSecond: $0 * 1_000_000) }
            do {
                for try await data in output {
                    bytes.feed(data)
                    await throttle?.pace(after: data.count)
                }
            } catch {
                print("（再生側）読み出しが失敗で終わった: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
    }
    // 状態・判断・知らせが変わったら出す
    var lastState = ""
    var lastVerdict = DescrambleJudge.Verdict.undecided
    var lastNotice: ReceptionNotice?
    func watch() {
        let state = describe(tuner.state)
        if state != lastState { say(state); lastState = state }
        if reception.descramble != lastVerdict { say("スクランブルの判断: \(reception.descramble)"); lastVerdict = reception.descramble }
        if reception.notice != lastNotice, let notice = reception.notice { say("知らせ: \(notice.text)"); lastNotice = notice }
    }
    let limit = Duration.milliseconds(Int(arguments.seconds * 1000))
    for frequency in arguments.frequencies {
        reception.tune(TuningTarget(frequency: frequency))
        let tuned = ContinuousClock.now
        while ContinuousClock.now - tuned < limit {
            watch()
            if case .failed = tuner.state { break }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    reception.stop()
    watch()
    try await Task.sleep(for: .seconds(1.5))
    say("受け取った \(bytes.value.packets) パケット（スクランブル \(bytes.value.scrambled)）")
}

/// 同梱の coax でスキャンし、一覧を保存して並べて出す
func scan(_ arguments: ProbeArguments) async throws {
    guard let folder = arguments.output else { throw ProbeFailure("--out にフォルダーを指定する") }
    guard let coax = arguments.coaxd.map({ URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("coax") })
            ?? CoaxPCSCSocket.locateCoax() else { throw ProbeFailure("--coaxd が要る（同じフォルダーの coax を使う）") }
    let directory = URL(fileURLWithPath: folder)
    let started = ContinuousClock.now
    let scanner = ChannelScanner(coax: coax, workDirectory: directory)
    if let seconds = arguments.cancelAfter {
        Task {
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            print("取り消す")
            scanner.cancel()
        }
    }
    let list = try await scanner.run { progress in
        print(String(format: "%6.1f 秒  [%d/%d] %@ %@（受信できた %d）", (ContinuousClock.now - started).seconds,
                     progress.completed, progress.total, progress.channel, progress.status, progress.found))
    }
    try ChannelStore(fileURL: directory.appendingPathComponent("channels.json")).save(list)
    print(String(format: "%.1f 秒で終わった", (ContinuousClock.now - started).seconds))
    printLineup(list)
}

func printLineup(_ list: ChannelList) {
    print("物理チャンネル \(list.channels.count)・一覧 \(list.lineup.count) 件")
    for entry in list.lineup {
        let key = entry.remoteControlKey.map { "\($0)" + (entry.branch > 1 ? "-\(entry.branch)" : "") } ?? "-"
        print("  \(key)\t\(entry.service.name)（\(entry.channel.name)・service \(entry.service.serviceID)）")
    }
    let hidden = list.channels.flatMap(\.services).filter { !$0.isVisible }
    print("隠したサービス \(hidden.count) 件: " + hidden.map { String(format: "%@(0x%02X)", $0.name, $0.type) }.joined(separator: "・"))
}

do {
    try await run()
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    FileHandle.standardError.write(Data("エラー: \(message)\n".utf8))
    exit(1)
}
