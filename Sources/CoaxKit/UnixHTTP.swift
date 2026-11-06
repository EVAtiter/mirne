import Foundation
import Network

/// HTTP/1.1 のやり取りで使う寸法と時間。
enum UnixHTTPLimits {
    /// 1 回の受信で受け取る最大バイト数。TS は約 2 MB/秒なので 64 KB で十分
    static let receiveChunk = 64 * 1024
    /// 応答ヘッダの最大長。coaxd のヘッダは 300 バイト程度
    static let maxHeadLength = 64 * 1024
    /// JSON の応答の最大長（coax の `maxAnswer` と同じ 8 MB）
    static let maxBodyLength = 8 << 20
    /// ソケットへの接続を待つ時間。同じ Mac のデーモンは即座に応じるか、まったく応じないかのどちらか
    static let connectTimeout: Duration = .seconds(1)
}

/// Unix ドメインソケット上の 1 本の接続。
///
/// URLSession は Unix ソケットを開けないので Network.framework を直接使う。
/// coaxd では「接続が閉じる = チューナーの解放」なので、1 回の要求に 1 本の接続を使い、
/// 使い終わったら必ず `cancel()` する。
final class UnixSocketConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.slack-kingdom.mirne.coax-socket")
    let path: String

    init(path: String) {
        self.path = path
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    deinit {
        connection.cancel()
    }

    /// 接続が使えるようになるまで待つ。
    ///
    /// ソケットが無いとき、NWConnection は `.failed` ではなく `.waiting`（再試行待ち）になる。
    /// 同じ Mac のデーモンは待っても現れないので、`.waiting` も失敗として扱う。
    func open() async throws {
        let path = self.path
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let resumed = ResumeOnce()
                    self.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if resumed.claim() { continuation.resume() }
                        case let .waiting(error), let .failed(error):
                            if resumed.claim() {
                                continuation.resume(throwing: CoaxError.daemonUnavailable(path: path, underlying: "\(error)"))
                            }
                        case .cancelled:
                            if resumed.claim() { continuation.resume(throwing: CoaxError.connectionClosed) }
                        default:
                            break
                        }
                    }
                    self.connection.start(queue: self.queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: UnixHTTPLimits.connectTimeout)
                throw CoaxError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: CoaxError.daemonUnavailable(path: self.path, underlying: "\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// 受け取れたぶんを返す。相手が閉じたら nil
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: UnixHTTPLimits.receiveChunk) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: CoaxError.daemonUnavailable(path: self.path, underlying: "\(error)"))
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// continuation を 1 度だけ再開するための印。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// HTTP の応答ヘッダ。
struct HTTPResponseHead: Sendable {
    let status: Int
    /// ヘッダ名は小文字にそろえる
    let headers: [String: String]

    var isChunked: Bool {
        headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false
    }

    var contentLength: Int? {
        headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// 1 本の接続の上で HTTP/1.1 の応答を読む。
///
/// 本文は chunked・Content-Length・接続が閉じるまで、の 3 通りに対応する。
/// coaxd の `/stream` は chunked、JSON の応答は Content-Length で返る。
final class HTTPResponseReader: @unchecked Sendable {
    private let connection: UnixSocketConnection
    private var buffer = Data()
    private var reachedEnd = false
    private var body: BodyState?

    /// 本文の読み進め方
    private enum BodyState {
        /// chunked。remaining は今の chunk の残り（0 なら次の長さの行から）
        case chunked(remaining: Int)
        /// Content-Length のぶんだけ
        case counted(remaining: Int)
        /// 接続が閉じるまで
        case untilClose
        case finished
    }

    init(connection: UnixSocketConnection) {
        self.connection = connection
    }

    func readHead() async throws -> HTTPResponseHead {
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: separator) {
                let headData = Data(buffer[buffer.startIndex..<range.lowerBound])
                discard(upTo: range.upperBound)
                return try Self.parseHead(headData)
            }
            if buffer.count > UnixHTTPLimits.maxHeadLength {
                throw CoaxError.malformedResponse("応答ヘッダが長すぎる")
            }
            guard try await fill() else { throw CoaxError.connectionClosed }
        }
    }

    /// 本文を最後まで読む（JSON の応答用）
    func readWholeBody(head: HTTPResponseHead) async throws -> Data {
        var body = Data()
        while let piece = try await nextBodyPiece(head: head) {
            body.append(piece)
            if body.count > UnixHTTPLimits.maxBodyLength {
                throw CoaxError.malformedResponse("応答の本文が大きすぎる")
            }
        }
        return body
    }

    /// 本文を、呼ばれたぶんだけ読む（読む側が引くまでソケットから受け取らない）。
    ///
    /// 先回りして読み溜めないことで、受け取る側の遅れがソケットを通じて coaxd に伝わる。
    /// coaxd は溢れたぶんを捨てて `dropped` に数え、書き込みが 30 秒止まれば接続を閉じる
    /// （coax の「読み出しの止まったクライアント」）。読み溜めると、この仕組みが働かないまま
    /// mirne のメモリが増え続ける（40 秒に 97 MB 溜まったのを実測）。
    func bodyPieces(head: HTTPResponseHead) -> ByteChunks {
        ByteChunks { try await self.nextBodyPiece(head: head) }
    }

    // MARK: - 本文の読み方

    /// 本文の次の切れ端。終わりなら nil。chunked の区切りは取り除く
    func nextBodyPiece(head: HTTPResponseHead) async throws -> Data? {
        try Task.checkCancellation()
        if body == nil {
            body = head.isChunked ? .chunked(remaining: 0) : head.contentLength.map { .counted(remaining: $0) } ?? .untilClose
        }
        switch body! {
        case .finished:
            return nil

        case let .counted(remaining):
            guard remaining > 0 else {
                body = .finished
                return nil
            }
            let piece = try await take(upTo: remaining)
            body = .counted(remaining: remaining - piece.count)
            return piece

        case .untilClose:
            if buffer.isEmpty, try await !fill() {
                body = .finished
                return nil
            }
            let piece = buffer
            buffer.removeAll()
            return piece

        case let .chunked(remaining):
            var left = remaining
            if left == 0 {
                let sizeLine = try await readLine()
                // chunk-ext（";" 以降）は使わない
                let hex = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    throw CoaxError.malformedResponse("chunk の長さを読めない: \(sizeLine)")
                }
                if size == 0 {
                    // trailer は読み飛ばす（空行まで）
                    while try await !readLine().isEmpty {}
                    body = .finished
                    return nil
                }
                left = size
            }
            let piece = try await take(upTo: left)
            left -= piece.count
            if left == 0 {
                guard try await readLine().isEmpty else {
                    throw CoaxError.malformedResponse("chunk の後に CRLF が無い")
                }
            }
            body = .chunked(remaining: left)
            return piece
        }
    }

    /// バッファから最大 limit バイトを取り出す。空なら 1 回だけ受信する
    private func take(upTo limit: Int) async throws -> Data {
        if buffer.isEmpty, try await !fill() { throw CoaxError.connectionClosed }
        let count = min(limit, buffer.count)
        let piece = Data(buffer.prefix(count))
        discard(upTo: buffer.startIndex + count)
        return piece
    }

    // MARK: - 下請け

    /// CRLF までの 1 行（CRLF を除く）
    private func readLine() async throws -> String {
        let crlf = Data("\r\n".utf8)
        while true {
            if let range = buffer.range(of: crlf) {
                let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                discard(upTo: range.upperBound)
                return line
            }
            guard try await fill() else { throw CoaxError.connectionClosed }
        }
    }

    /// バッファの先頭から end の手前までを捨てる。
    /// Data の removeFirst・removeSubrange は先頭を削っても領域を手放さず、続く append で
    /// 領域が伸び続ける（受信したぶんだけメモリが増える）ので、残りを新しい Data へ写す
    private func discard(upTo end: Data.Index) {
        buffer = end >= buffer.endIndex ? Data() : buffer.subdata(in: end..<buffer.endIndex)
    }

    /// 受信してバッファに足す。相手が閉じていれば false
    private func fill() async throws -> Bool {
        if reachedEnd { return false }
        guard let data = try await connection.receive() else {
            reachedEnd = true
            return false
        }
        buffer.append(data)
        return true
    }

    static func parseHead(_ data: Data) throws -> HTTPResponseHead {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw CoaxError.malformedResponse("ステータス行が無い") }
        let statusLine = lines.removeFirst()
        // "HTTP/1.1 200 OK"
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            throw CoaxError.malformedResponse("ステータス行を読めない: \(statusLine)")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPResponseHead(status: status, headers: headers)
    }
}

/// 読む側が引いたぶんだけ作られるバイト列。
///
/// AsyncThrowingStream は作る側が先回りして際限なく溜め込めるので、TS の経路には使わない。
/// 読む側は 1 つだけ（複数のタスクから同時に引かない）。
public struct ByteChunks: AsyncSequence, Sendable {
    public typealias Element = Data
    let produce: @Sendable () async throws -> Data?

    public init(_ produce: @escaping @Sendable () async throws -> Data?) {
        self.produce = produce
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let produce: @Sendable () async throws -> Data?
        public mutating func next() async throws -> Data? {
            try await produce()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(produce: produce)
    }
}

/// GET の要求文。
enum HTTPRequest {
    static func get(_ pathAndQuery: String, headers: [String: String] = [:], keepAlive: Bool) -> Data {
        var text = "GET \(pathAndQuery) HTTP/1.1\r\n"
        // coaxd は Host がループバックか localhost の要求だけを受け付ける（Unix ソケットでは任意だが揃えておく）
        text += "Host: localhost\r\n"
        text += "User-Agent: mirne\r\n"
        if !keepAlive {
            text += "Connection: close\r\n"
        }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}
