import Foundation
import os

/// スキャンの進み具合。
public struct ScanProgress: Sendable, Equatable {
    /// 終わったチャンネルの数
    public var completed: Int
    /// 調べるチャンネルの数
    public var total: Int
    /// 最後に終わったチャンネル（地上波は物理チャンネルの番号）
    public var channel: String
    /// そのチャンネルの結果（`found`・`no lock` など。coax の表示のまま）
    public var status: String
    /// ここまでに受信できたチャンネルの数
    public var found: Int

    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    /// 受信できたか
    public var isFound: Bool { Self.isFound(status) }

    static func isFound(_ status: String) -> Bool { status.hasPrefix("found") }

    /// `coax scan` が標準エラー出力（端末でないとき）に 1 チャンネルごとに書く行を読む。
    /// 例: `[28/113] ISDBT/40 ... found (ts, 4491696 bytes) 17.27 Mbps CNR 25.3dB -51dBm`・`[1/113] ISDBT/13 ... no lock`。
    /// 結果は括弧の前まで（`found`・`no lock`）
    static func parse(line: String) -> (completed: Int, total: Int, channel: String, status: String)? {
        let pattern = /^\[(\d+)\/(\d+)\]\s+(?:[A-Z0-9_\/]+\/)?(\S+)\s+\.\.\.\s+([^(]+)/
        guard let match = line.firstMatch(of: pattern), let completed = Int(match.1), let total = Int(match.2) else { return nil }
        return (completed, total, String(match.3), match.4.trimmingCharacters(in: .whitespaces))
    }
}

/// スキャンの失敗。
public enum ChannelScanError: Error, LocalizedError {
    /// `coax` が見つからない
    case coaxNotFound
    /// `coax scan` が失敗で終わった。`said` は標準エラー出力の終わりの部分
    case failed(status: Int32, said: String)
    /// 取り消した
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .coaxNotFound: "coax が見つかりません"
        case let .failed(status, said): said.isEmpty ? "スキャンに失敗しました（終了コード \(status)）" : "スキャンに失敗しました: \(said)"
        case .cancelled: "スキャンを取り消しました"
        }
    }
}

/// 同梱の `coax scan --discover ISDBT` を走らせ、結果を取り込む。
///
/// スキャンの間はチューナーを占有する。視聴を止めてから始めること（スキャンの優先度は視聴より低いので、
/// 視聴中は空かない）。途中で止めても、coax が進捗ファイルに残したぶんは次のスキャンで使われる。
public final class ChannelScanner: @unchecked Sendable {
    /// 標準エラー出力のうち、失敗の表示に添える長さ
    static let complaintLength = 2_000

    private let coax: URL
    private let workDirectory: URL
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "tuner")

    /// - Parameters:
    ///   - coax: `coax` の実行ファイル（既定は同梱品）
    ///   - workDirectory: 結果と進捗ファイルを置く場所
    public init(coax: URL, workDirectory: URL) {
        self.coax = coax
        self.workDirectory = workDirectory
    }

    /// 走らせて、終わったら取り込んだ一覧を返す。`onProgress` はチャンネルが 1 つ終わるたびに呼ぶ
    public func run(onProgress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ChannelList {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let output = workDirectory.appendingPathComponent("scan.json")
        try? FileManager.default.removeItem(at: output)

        let process = Process()
        process.executableURL = coax
        process.arguments = ["scan", "--discover", "ISDBT", "--priority", String(TunerPriority.scan), "--output", output.path]
        process.currentDirectoryURL = workDirectory
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let lines = LineCollector(complaintLength: Self.complaintLength) { line in
            guard let parsed = ScanProgress.parse(line: line) else { return nil }
            return parsed
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for progress in lines.feed(data) { onProgress(progress) }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try lock.withLock {
                    guard !cancelled else { throw ChannelScanError.cancelled }
                    self.process = process
                    try process.run()
                }
                Self.logger.info("スキャンを始めた（pid \(process.processIdentifier, privacy: .public)）")
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = nil
        for progress in lines.feed(errorPipe.fileHandleForReading.readDataToEndOfFile()) { onProgress(progress) }
        lock.withLock { self.process = nil }

        if lock.withLock({ cancelled }) { throw ChannelScanError.cancelled }
        guard status == 0 else {
            throw ChannelScanError.failed(status: status, said: lines.tail)
        }
        Self.logger.info("スキャンが終わった（受信できたチャンネル \(lines.found, privacy: .public)）")
        return try ChannelList.importing(scanResult: Data(contentsOf: output))
    }

    /// 取り消す。`coax scan` に SIGTERM を送る
    public func cancel() {
        let running = lock.withLock {
            cancelled = true
            return process
        }
        running?.terminate()
    }
}

/// 標準エラー出力を行に分け、進み具合の行を読む。終わりの部分は失敗の表示のために残す。
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var kept = ""
    private let complaintLength: Int
    private let parse: (String) -> (completed: Int, total: Int, channel: String, status: String)?
    private(set) var found = 0

    init(complaintLength: Int, parse: @escaping (String) -> (completed: Int, total: Int, channel: String, status: String)?) {
        self.complaintLength = complaintLength
        self.parse = parse
    }

    var tail: String { lock.withLock { kept.trimmingCharacters(in: .whitespacesAndNewlines) } }

    func feed(_ data: Data) -> [ScanProgress] {
        lock.withLock {
            pending.append(data)
            var progresses: [ScanProgress] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending = pending.subdata(in: pending.index(after: newline)..<pending.endIndex)
                kept = String((kept + line + "\n").suffix(complaintLength))
                guard let parsed = parse(line) else { continue }
                if ScanProgress.isFound(parsed.status) { found += 1 }
                progresses.append(ScanProgress(completed: parsed.completed, total: parsed.total, channel: parsed.channel,
                                               status: parsed.status, found: found))
            }
            return progresses
        }
    }
}
