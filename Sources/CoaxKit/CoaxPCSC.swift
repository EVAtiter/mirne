import Foundation
import os

/// `coax pcsc` が作る PC/SC ソケット（チューナー内蔵のカードスロットを外部フィルタへ渡す口）。
///
/// coax の `ensurePCSC`（`pkg/cli/pcsc.go`）と同じ手順で用意する。
/// 外部フィルタには、このソケットのパスを `PCSCLITE_CSOCK_NAME` で渡す（pcsc-lite のクライアント
/// ライブラリが読む環境変数）。mirne はカードとのやり取りの中身には関わらない。
public final class CoaxPCSCSocket: @unchecked Sendable {
    /// `coax pcsc` が誰にも使われなくなってから終了するまでの時間（coax の `pcscIdle` と同じ）。
    /// 番組の切れ目で再起動しない長さで、間違って起動しても居残らない短さ
    static let idleAfter = "1m"

    /// ソケットのパス
    public let path: String
    /// 開いたままにしておく接続。これがある間 `coax pcsc` はアイドル終了しない
    private var heldDescriptor: Int32?
    private let lock = NSLock()

    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "tuner")

    private init(path: String, heldDescriptor: Int32) {
        self.path = path
        self.heldDescriptor = heldDescriptor
    }

    deinit {
        release()
    }

    /// 既定のソケットのパス（`PCSCLITE_CSOCK_NAME` → coaxd のソケットと同じディレクトリの `pcscd.comm`）
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let named = environment["PCSCLITE_CSOCK_NAME"], !named.isEmpty {
            return named
        }
        return (CoaxSocket.directory(environment: environment) as NSString).appendingPathComponent("pcscd.comm")
    }

    /// 同梱した `coax` の場所
    public static func locateCoax(bundle: Bundle = .main) -> URL? {
        HelperLocation.find("coax", bundle: bundle)
    }

    /// ソケットを用意する。すでに誰かが用意していればそれを使い、無ければ `coax pcsc` を起動する
    public static func ensure(coax: URL, coaxdSocket: String = CoaxSocket.defaultPath(),
                              path: String = defaultPath()) async throws -> CoaxPCSCSocket {
        try CoaxSocket.validate(path)
        if let held = UnixSocketProbe.connect(path: path) {
            return CoaxPCSCSocket(path: path, heldDescriptor: held)
        }
        let started = ContinuousClock.now
        let (pid, complaints) = try DetachedProcess.spawn(
            executable: coax,
            arguments: ["pcsc", "--socket", path, "--idle", idleAfter, "--host", coaxdSocket])
        logger.info("coax pcsc を起動した（pid \(pid, privacy: .public)）")
        while ContinuousClock.now - started < CoaxStartTiming.deadline {
            try await Task.sleep(for: CoaxStartTiming.pollInterval)
            if let held = UnixSocketProbe.connect(path: path) {
                let elapsed = ContinuousClock.now - started
                logger.info("PC/SC のソケットが応答した（起動から \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)）")
                return CoaxPCSCSocket(path: path, heldDescriptor: held)
            }
        }
        throw CoaxError.daemonDidNotStart(said: complaints.text)
    }

    /// 保持している接続を閉じる。`coax pcsc` は誰も使わなくなれば 1 分後に終了する
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        if let descriptor = heldDescriptor {
            close(descriptor)
            heldDescriptor = nil
        }
    }
}
