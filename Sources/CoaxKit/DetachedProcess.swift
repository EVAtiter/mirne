import Foundation

/// mirne から切り離して起動する常駐プロセス（coaxd・coax pcsc）。
///
/// どちらも、誰も使わなくなれば自分で終了する。mirne は止める手続きを持たず、
/// 異常終了しても一緒に止まらないよう setsid で切り離す（coax の `Detach` と同じ）。
enum DetachedProcess {
    /// 起動して pid を返す。標準エラーは `DaemonComplaints` が終了まで読み続ける
    static func spawn(executable: URL, arguments: [String]) throws -> (pid: pid_t, complaints: DaemonComplaints) {
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else {
            throw CoaxError.daemonDidNotStart(said: "pipe: \(String(cString: strerror(errno)))")
        }
        let (readEnd, writeEnd) = (pipe[0], pipe[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETSID: mirne のセッションから切り離す
        // CLOEXEC_DEFAULT: 上で用意した 0〜2 以外の記述子（mirne が開いているソケットなど）を渡さない
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argumentVector = [executable.path] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = argumentVector.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, environ)
        close(writeEnd)
        guard result == 0 else {
            close(readEnd)
            throw CoaxError.daemonDidNotStart(said: "posix_spawn: \(String(cString: strerror(result)))")
        }
        return (pid, DaemonComplaints(readingFrom: readEnd))
    }
}

/// デーモンが標準エラーに書いたこと。
///
/// パイプはデーモンが終了するまで読み続ける。読むのをやめるとパイプが詰まってデーモンが
/// 書き込みで止まり、読む側を閉じると Go のデーモンは標準エラーへの書き込みで SIGPIPE を受けて終了する。
/// そのため、読み取りのハンドラーが自分を強く参照し、デーモンの終了（EOF）まで生き続ける。
final class DaemonComplaints: @unchecked Sendable {
    /// 取っておく量（起動に失敗したデーモンは最初の行で理由を言う。coax の complaintRoom と同じ）
    static let room = 4 << 10

    private let handle: FileHandle
    private let lock = NSLock()
    private var collected = Data()

    init(readingFrom descriptor: Int32) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // デーモンが終了した。ここで循環参照が切れ、記述子が閉じる
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            let room = Self.room - self.collected.count
            if room > 0 {
                self.collected.append(data.prefix(room))
            }
            self.lock.unlock()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: collected, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Unix ソケットに接続できるかを確かめる（HTTP は話さない）。
///
/// `coax pcsc` のソケットは pcsc-lite の独自プロトコルなので、接続できるかだけを見る。
/// 返した記述子を開いたままにしておくと「使っている者がいる」ことになり、`coax pcsc` が
/// アイドルで終了しない（coax の `ensurePCSC` と同じ考え方）。
enum UnixSocketProbe {
    /// 接続できれば記述子を返す。呼び出し側が close する
    static func connect(path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination -> Bool in
                let length = strlen(source)
                guard length < capacity else { return false }
                destination.copyMemory(from: UnsafeRawBufferPointer(start: source, count: length + 1))
                return true
            }
        }
        guard copied else {
            close(descriptor)
            return nil
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }
}
