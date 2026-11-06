import Foundation

/// CECH-ZD1 J を探すときの名前。
public enum CoaxBackendName {
    /// `GET /tuners` の `backend`
    public static let cechZD1J = "cech-zd1j"
}

/// coaxd のエラーコード（coax の `pkg/host/wire.go`）。
enum CoaxProblemCode {
    static let invalidParameter = "invalid_parameter"
    static let unknownTuner = "unknown_tuner"
    static let tunerBusy = "tuner_busy"
    static let unsupported = "unsupported"
    static let tuneFailed = "tune_failed"
    static let noLock = "no_lock"
    /// ロックしたが TS ではないものが来た（何もつながっていないアンテナ線）
    static let noSync = "no_sync"
    static let deviceGone = "device_gone"
    static let noDevices = "no_devices"
    static let noAccess = "no_access"
    static let `internal` = "internal"
}

/// 選局の失敗を、利用者がとるべき行動で分けたもの。
public enum TunerFailure: Error, Sendable, Equatable {
    /// CECH-ZD1 J が見つからない（つながっていない・抜かれた）
    case notConnected
    /// デバイスを開けない・選局をハードウェアが拒んだ（抜き差しで直ることが多い）
    case cannotOpen(detail: String)
    /// ほかの接続がチューナーを使っている
    case busy
    /// 選局したが受信できない（アンテナ・受信状態）。C/N が測れていれば入る
    case noSignal(cnr: Double?)
    /// coaxd を起動できない・応答しない
    case daemon(detail: String)
    /// 外部フィルタを起動できない（設定のコマンドを確かめる）
    case filter(detail: String)
    /// 上のどれでもない
    case other(detail: String)

    /// coaxd とのやり取りの失敗を分類する
    public init(_ error: any Error) {
        if let failure = error as? TunerFailure {
            self = failure
            return
        }
        guard let coax = error as? CoaxError else {
            self = .other(detail: error.localizedDescription)
            return
        }
        let detail = coax.errorDescription ?? "\(coax)"
        switch coax {
        case .socketPathTooLong, .daemonUnavailable, .daemonNotFound, .daemonDidNotStart, .timedOut:
            self = .daemon(detail: detail)
        case .malformedResponse, .connectionClosed:
            self = .other(detail: detail)
        case let .http(_, problem, tuneStatus):
            switch problem?.code {
            case CoaxProblemCode.noLock, CoaxProblemCode.noSync:
                self = .noSignal(cnr: tuneStatus?.cnr)
            case CoaxProblemCode.tunerBusy:
                self = .busy
            case CoaxProblemCode.deviceGone, CoaxProblemCode.noDevices, CoaxProblemCode.unknownTuner:
                self = .notConnected
            case CoaxProblemCode.noAccess, CoaxProblemCode.tuneFailed:
                self = .cannotOpen(detail: detail)
            default:
                self = .other(detail: detail)
            }
        }
    }

    /// 同じ要求をやり直せば通る見込みがあるか。
    ///
    /// coaxd が落ちた・応答が壊れたときだけ。つながっていない・使用中・受信できないは、
    /// 利用者が何かするまで結果が変わらないので、やり直さずに表示する
    public var isWorthRetrying: Bool {
        switch self {
        case .daemon, .other: true
        case .notConnected, .cannotOpen, .busy, .noSignal, .filter: false
        }
    }

    /// 画面に出す見出し
    public var title: String {
        switch self {
        case .notConnected: "チューナーが接続されていません"
        case .cannotOpen: "チューナーを開けません"
        case .busy: "チューナーは使用中です"
        case .noSignal: "受信できません"
        case .daemon: "coaxd を起動できません"
        case .filter: "外部フィルタを起動できません"
        case .other: "選局できませんでした"
        }
    }

    /// 見出しの下に出す、次にすること
    public var advice: String {
        switch self {
        case .notConnected:
            "CECH-ZD1 J を USB につないでください。"
        case .cannotOpen:
            "CECH-ZD1 J を USB から抜き、挿し直してから選局してください。"
        case .busy:
            "ほかのアプリがチューナーを使っています。そちらを終えてから選局してください。"
        case let .noSignal(cnr):
            if let cnr {
                String(format: "アンテナ線の接続と受信状態を確かめてください（C/N %.1f dB）。", cnr)
            } else {
                "アンテナ線の接続と受信状態を確かめてください。"
            }
        case let .daemon(detail), let .filter(detail), let .other(detail):
            detail
        }
    }
}
