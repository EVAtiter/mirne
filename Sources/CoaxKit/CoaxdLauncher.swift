import Foundation
import os

/// 常駐プロセスの起動の待ち方。coax の `coax` CLI（`pkg/host/client.go`・`pkg/cli/pcsc.go`）と同じ値。
enum CoaxStartTiming {
    /// 起動したプロセスに接続を試す間隔
    static let pollInterval: Duration = .milliseconds(50)
    /// 起動してから応答するまで待つ上限
    static let deadline: Duration = .seconds(10)
}

/// coaxd が動いていなければ起動する。
///
/// coaxd は接続が無い状態が続くと自分で終了する（既定 15 秒）。mirne は止める手続きを持たず、
/// 視聴の接続を閉じればよい。チューナーは接続が閉じた時点で解放される。
public struct CoaxdLauncher: Sendable {
    /// 起動する coaxd の実行ファイル
    public let executable: URL
    public let client: CoaxClient

    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "tuner")

    public init(executable: URL, client: CoaxClient = CoaxClient()) {
        self.executable = executable
        self.client = client
    }

    /// coaxd の場所を決める。
    ///
    /// 環境変数 `COAXD` → .app の `Contents/Helpers/coaxd` → この実行ファイルと同じフォルダー の順。
    /// 同梱品を先に探すのは、`PATH` 上の別の版を拾わないため（coax の `locate` と同じ考え方）。
    public static func locate(bundle: Bundle = .main,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let named = environment["COAXD"], !named.isEmpty {
            return URL(fileURLWithPath: named)
        }
        return HelperLocation.find("coaxd", bundle: bundle)
    }

    /// 応答するデーモンを用意する。すでに動いていればそれを使う
    @discardableResult
    public func ensureRunning() async throws -> CoaxVersion {
        if let version = try? await client.version() {
            return version
        }
        try CoaxSocket.validate(client.socketPath)
        let started = ContinuousClock.now
        let (pid, complaints) = try DetachedProcess.spawn(executable: executable,
                                                          arguments: ["--socket", client.socketPath])
        Self.logger.info("coaxd を起動した（pid \(pid, privacy: .public)）: \(executable.path, privacy: .public)")
        while ContinuousClock.now - started < CoaxStartTiming.deadline {
            try await Task.sleep(for: CoaxStartTiming.pollInterval)
            if let version = try? await client.version() {
                let elapsed = ContinuousClock.now - started
                Self.logger.info("coaxd \(version.version, privacy: .public) が応答した（起動から \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)）")
                return version
            }
        }
        throw CoaxError.daemonDidNotStart(said: complaints.text)
    }
}

/// .app に同梱したヘルパーの場所。
enum HelperLocation {
    /// `Contents/Helpers/<name>` → この実行ファイルと同じフォルダー の順に探す
    static func find(_ name: String, bundle: Bundle = .main) -> URL? {
        let fileManager = FileManager.default
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        if fileManager.isExecutableFile(atPath: helper.path) {
            return helper
        }
        if let executable = bundle.executableURL {
            let beside = executable.deletingLastPathComponent().appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: beside.path) {
                return beside
            }
        }
        return nil
    }
}
