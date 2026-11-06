import Foundation

/// coaxd が返す失敗の本文（`{"error":{"code":…,"message":…,"reason":…},"status":{…}}`）。
public struct CoaxProblem: Decodable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let reason: String?
}

/// 選局まで進んでから失敗したときに、それまでに測れた値（`/tune` の応答と同じ形の一部）。
public struct CoaxTuneStatus: Decodable, Sendable, Equatable {
    public let tuner: String?
    public let backend: String?
    public let locked: Bool?
    /// 信号強度（dBm）
    public let strength: Double?
    /// C/N（dB）
    public let cnr: Double?
    public let elapsedMilliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case tuner, backend, locked, strength, cnr
        case elapsedMilliseconds = "elapsed_ms"
    }
}

struct CoaxFailureBody: Decodable {
    let error: CoaxProblem
    let status: CoaxTuneStatus?
}

/// coaxd とのやり取りで起きる失敗。
public enum CoaxError: Error, Sendable {
    /// ソケットのパスが macOS の上限を超えている
    case socketPathTooLong(path: String, length: Int, limit: Int)
    /// ソケットに接続できない（デーモンが動いていない）
    case daemonUnavailable(path: String, underlying: String)
    /// coaxd の実行ファイルが見つからない
    case daemonNotFound
    /// coaxd を起動したが、時間内に応答しなかった。`said` はデーモンが標準エラーに書いたこと
    case daemonDidNotStart(said: String)
    /// HTTP のエラー応答。coaxd の本文が読めれば `problem` に入る
    case http(status: Int, problem: CoaxProblem?, tuneStatus: CoaxTuneStatus?)
    /// HTTP として読めない応答
    case malformedResponse(String)
    /// 応答の途中で接続が切れた
    case connectionClosed
    /// 時間内に応答が無かった
    case timedOut
}

extension CoaxError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .socketPathTooLong(path, length, limit):
            "coaxd のソケットのパスが長すぎます（\(length) バイト。上限 \(limit)）: \(path)"
        case let .daemonUnavailable(path, underlying):
            "coaxd に接続できません（\(path)）: \(underlying)"
        case .daemonNotFound:
            "coaxd が見つかりません"
        case let .daemonDidNotStart(said):
            said.isEmpty ? "coaxd を起動しましたが応答がありません" : "coaxd を起動しましたが応答がありません: \(said)"
        case let .http(status, problem, _):
            if let problem { "coaxd が \(status) を返しました: \(problem.code)（\(problem.message)）" }
            else { "coaxd が \(status) を返しました" }
        case let .malformedResponse(detail):
            "coaxd の応答を読めません: \(detail)"
        case .connectionClosed:
            "coaxd との接続が途中で切れました"
        case .timedOut:
            "coaxd から時間内に応答がありません"
        }
    }

    /// coaxd のエラーコード（`no_lock`・`tuner_busy` など）。HTTP のエラー以外は nil
    public var problemCode: String? {
        if case let .http(_, problem, _) = self { return problem?.code }
        return nil
    }
}
