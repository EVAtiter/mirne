import Foundation

/// `GET /version` の応答。
public struct CoaxVersion: Decodable, Sendable {
    public let version: String
    public let commit: String?
    /// 起動時刻（RFC3339 の UTC）
    public let started: String?
    public let arch: String?
}

/// `GET /tuners` の 1 デバイス。
public struct CoaxDevice: Decodable, Sendable, Identifiable {
    public let name: String
    public let backend: String
    public let description: String
    public let deliveries: [String]
    public let open: Bool
    public let tuners: [CoaxTuner]

    public var id: String { name }
}

/// デバイスに載っている 1 チューナー。
public struct CoaxTuner: Decodable, Sendable, Identifiable {
    public let id: String
    public let index: Int
    public let name: String
    public let deliveries: [String]
    public let leased: Bool
    /// 使用中のときの優先度
    public let priority: Int?
}

/// `GET /tuners/{id}` の応答のうち、受信状態にかかわるもの。使用中のときだけ値が入る。
public struct CoaxTunerStatus: Decodable, Sendable {
    public let id: String
    public let leased: Bool
    public let priority: Int?
    public let locked: Bool?
    /// C/N（dB）
    public let cnr: Double?
    /// 信号強度（dBm）
    public let strength: Double?
    /// 読み出しが追いつかず coaxd が捨てた数
    public let dropped: Int?
    public let stream: CoaxStreamStatistics?
}

/// ストリームを開いてからの累計（coax の「ストリーム統計」）。
public struct CoaxStreamStatistics: Decodable, Sendable {
    public let format: String
    public let bytes: Int
    public let packets: Int
    public let skipped: Int?
    public let syncLosses: Int?
    /// continuity_counter が連続していなかったパケット
    public let discontinuities: Int?
    public let nulls: Int?
    /// 訂正しきれなかったパケット（電波が弱い）
    public let errors: Int?
    public let scrambled: Int?

    enum CodingKeys: String, CodingKey {
        case format, bytes, packets, skipped, discontinuities, nulls, errors, scrambled
        case syncLosses = "sync_losses"
    }
}

/// 選局の要求。
public struct CoaxStreamRequest: Sendable {
    /// 伝送方式（`ISDBT` など）
    public var system: String
    /// 周波数（Hz）
    public var frequency: Int
    /// チューナー ID。nil ならデーモンが空きから選ぶ
    public var tunerID: String?
    /// `X-Coax-Priority`。視聴は 0、スキャンは負の値
    public var priority: Int

    public init(system: String = "ISDBT", frequency: Int, tunerID: String? = nil, priority: Int = 0) {
        self.system = system
        self.frequency = frequency
        self.tunerID = tunerID
        self.priority = priority
    }

    var pathAndQuery: String {
        var items = [URLQueryItem(name: "system", value: system),
                     URLQueryItem(name: "freq", value: String(frequency))]
        if let tunerID {
            items.append(URLQueryItem(name: "tuner", value: tunerID))
        }
        var components = URLComponents()
        components.path = "/stream"
        components.queryItems = items
        return components.string ?? "/stream"
    }
}

/// 受信中のストリーム。
///
/// `bytes` を読み終えるか、`close()` するか、この値を手放すと接続が閉じ、チューナーが解放される。
public final class CoaxStream: Sendable {
    /// 実際に割り当てられたチューナー（`X-Coax-Tuner`）
    public let tunerID: String?
    /// 保持されている優先度（`X-Coax-Priority`）
    public let priority: Int?
    /// TS の本文。届いた順のバイト列
    public let bytes: ByteChunks

    private let connection: UnixSocketConnection

    init(connection: UnixSocketConnection, head: HTTPResponseHead, bytes: ByteChunks) {
        self.connection = connection
        tunerID = head.headers["x-coax-tuner"]
        priority = head.headers["x-coax-priority"].flatMap { Int($0) }
        self.bytes = bytes
    }

    deinit {
        connection.cancel()
    }

    /// 接続を閉じてチューナーを解放する
    public func close() {
        connection.cancel()
    }
}

/// coaxd の HTTP API のクライアント。
///
/// 要求ごとに接続を張る。coaxd は状態を持たず、チューナーの占有は接続に結び付いているため
/// （接続を使い回すと、解放したつもりのチューナーを持ち続けることになる）。
public struct CoaxClient: Sendable {
    public let socketPath: String

    public init(socketPath: String = CoaxSocket.defaultPath()) {
        self.socketPath = socketPath
    }

    public func version() async throws -> CoaxVersion {
        try await getJSON("/version")
    }

    /// チューナーの一覧。デバイスは開かない
    public func devices() async throws -> [CoaxDevice] {
        try await getJSON("/tuners")
    }

    /// 指定したバックエンドの最初のチューナー。つながっていなければ nil
    public func findTuner(backend: String = CoaxBackendName.cechZD1J) async throws -> CoaxTuner? {
        try await devices().first { $0.backend == backend }?.tuners.first
    }

    /// 1 チューナーの状態。ストリーム中でも呼べる（coaxd はリースではなく観測者として数える）
    public func tunerStatus(id: String) async throws -> CoaxTunerStatus {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await getJSON("/tuners/\(escaped)")
    }

    /// 選局して TS を受け取り始める。
    ///
    /// coaxd はロックと同期の検査が済んでから応答ヘッダを返すので、この関数が戻った時点で
    /// 受信は成立している。ロックしなければ `CoaxError.http`（`no_lock`）になる。
    public func openStream(_ request: CoaxStreamRequest) async throws -> CoaxStream {
        let connection = try await connect()
        do {
            try await connection.send(HTTPRequest.get(request.pathAndQuery,
                                                      headers: ["X-Coax-Priority": String(request.priority)],
                                                      keepAlive: false))
            let reader = HTTPResponseReader(connection: connection)
            let head = try await reader.readHead()
            guard head.status == 200 else {
                throw try await failure(head: head, reader: reader)
            }
            return CoaxStream(connection: connection, head: head, bytes: reader.bodyPieces(head: head))
        } catch {
            connection.cancel()
            throw error
        }
    }

    // MARK: - 下請け

    private func connect() async throws -> UnixSocketConnection {
        try CoaxSocket.validate(socketPath)
        let connection = UnixSocketConnection(path: socketPath)
        do {
            try await connection.open()
        } catch {
            connection.cancel()
            throw error
        }
        return connection
    }

    private func getJSON<Value: Decodable>(_ path: String) async throws -> Value {
        let connection = try await connect()
        defer { connection.cancel() }
        try await connection.send(HTTPRequest.get(path, keepAlive: false))
        let reader = HTTPResponseReader(connection: connection)
        let head = try await reader.readHead()
        guard head.status == 200 else {
            throw try await failure(head: head, reader: reader)
        }
        let body = try await reader.readWholeBody(head: head)
        do {
            return try JSONDecoder().decode(Value.self, from: body)
        } catch {
            throw CoaxError.malformedResponse("\(path) の JSON: \(error)")
        }
    }

    private func failure(head: HTTPResponseHead, reader: HTTPResponseReader) async throws -> CoaxError {
        let body = (try? await reader.readWholeBody(head: head)) ?? Data()
        let decoded = try? JSONDecoder().decode(CoaxFailureBody.self, from: body)
        return CoaxError.http(status: head.status, problem: decoded?.error, tuneStatus: decoded?.status)
    }
}
