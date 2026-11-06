import Foundation
import os

/// 外部フィルタのコマンド（設定で指定する）。
///
/// 標準入力で TS を受け取り、標準出力へ TS を返すものなら何でもよい。
/// mirne はその中身を関知しない。
public struct ExternalFilterCommand: Sendable, Codable, Equatable {
    /// 実行ファイル。`/` を含まなければ `PATH` から探す（GUI アプリの `PATH` は短いので、絶対パスを推奨）
    public var executable: String
    public var arguments: [String]
    /// 追加する環境変数（mirne の環境に上書きで足す）
    public var environment: [String: String]

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// 外部フィルタの止め方。
enum ExternalFilterTiming {
    /// 標準入力を閉じてから、自分で終了するのを待つ時間
    static let exitGrace: Duration = .seconds(1)
    /// SIGTERM を送ってから SIGKILL までの時間
    static let terminateGrace: Duration = .seconds(1)
    /// 終了を確かめる間隔
    static let reapPoll: Duration = .milliseconds(20)
    /// 標準出力を 1 回に読む最大バイト数
    static let readChunk = 64 * 1024
}

/// 外部フィルタのプロセス。
///
/// 標準入力・標準出力・標準エラーをパイプでつなぐ。mirne が異常終了すると標準入力が閉じ、
/// フィルタは EOF で終了する（setsid で切り離さないのは、mirne と運命を共にさせるため）。
/// フィルタは自分のプロセスグループで動かし、止めるときはグループごと止める
/// （`/bin/sh -c` で起動したときの子プロセスを残さないため）。
public final class ExternalFilter: @unchecked Sendable {
    public let pid: pid_t
    /// 標準出力から届いた TS。読む側が引いたぶんだけ読む（先回りして溜め込まない）。
    /// 読むのが遅れるとフィルタが書き込みで止まり、その遅れが標準入力 → coaxd へと伝わる
    public let output: ByteChunks

    private let inputDescriptor: Int32
    private let writeQueue = DispatchQueue(label: "com.slack-kingdom.mirne.filter-input")
    private let complaints: DaemonComplaints
    private let lock = NSLock()
    private var inputClosed = false
    private var exitStatus: Int32?

    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "ts")

    private init(pid: pid_t, inputDescriptor: Int32, outputDescriptor: Int32, complaints: DaemonComplaints) {
        self.pid = pid
        self.inputDescriptor = inputDescriptor
        self.complaints = complaints
        let reader = PipeReader(descriptor: outputDescriptor)
        output = ByteChunks { try await reader.next() }
    }

    deinit {
        closeInput()
    }

    /// フィルタを起動する。`extraEnvironment` はコマンドの設定より後に重ねる（PC/SC のソケットなど）
    public static func start(_ command: ExternalFilterCommand,
                             extraEnvironment: [String: String] = [:]) throws -> ExternalFilter {
        var inputPipe: [Int32] = [0, 0]
        var outputPipe: [Int32] = [0, 0]
        var errorPipe: [Int32] = [0, 0]
        guard pipe(&inputPipe) == 0, pipe(&outputPipe) == 0, pipe(&errorPipe) == 0 else {
            throw ExternalFilterError.io("pipe: \(String(cString: strerror(errno)))")
        }
        // フィルタが先に終了しても、標準入力への書き込みで mirne が SIGPIPE を受けて落ちないようにする
        _ = fcntl(inputPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // 0〜2 以外の記述子（coaxd との接続など）をフィルタに渡さない。
        // 自分のプロセスグループ（グループ ID = フィルタの pid）で動かす
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var environment = ProcessInfo.processInfo.environment
        environment.merge(command.environment) { $1 }
        environment.merge(extraEnvironment) { $1 }
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var argv: [UnsafeMutablePointer<CChar>?] = ([command.executable] + command.arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = command.executable.contains("/")
            ? posix_spawn(&pid, command.executable, &actions, &attributes, &argv, &envp)
            : posix_spawnp(&pid, command.executable, &actions, &attributes, &argv, &envp)
        // 子に渡した側を閉じる（閉じないと EOF が届かない）
        close(inputPipe[0])
        close(outputPipe[1])
        close(errorPipe[1])
        guard result == 0 else {
            close(inputPipe[1])
            close(outputPipe[0])
            close(errorPipe[0])
            throw ExternalFilterError.launchFailed("\(command.executable): \(String(cString: strerror(result)))")
        }
        logger.info("外部フィルタを起動した（pid \(pid, privacy: .public)）")
        return ExternalFilter(pid: pid, inputDescriptor: inputPipe[1], outputDescriptor: outputPipe[0],
                              complaints: DaemonComplaints(readingFrom: errorPipe[0]))
    }

    /// 標準入力へ書く。フィルタが読むのを待つので、ここで待つことが上流への背圧になる
    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                let failure: Error? = data.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let written = Darwin.write(self.inputDescriptor, buffer.baseAddress! + offset, buffer.count - offset)
                        if written > 0 {
                            offset += written
                        } else if written < 0, errno == EINTR {
                            continue
                        } else if errno == EPIPE {
                            return ExternalFilterError.exited(stderr: self.complaints.text)
                        } else {
                            return ExternalFilterError.io("write: \(String(cString: strerror(errno)))")
                        }
                    }
                    return nil
                }
                if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
            }
        }
    }

    /// 標準入力を閉じる（フィルタは EOF を受けて、残りを出し切ってから終了する）
    public func closeInput() {
        lock.lock()
        defer { lock.unlock() }
        guard !inputClosed else { return }
        inputClosed = true
        // 書き込み中のものを待ってから閉じる
        writeQueue.async { close(self.inputDescriptor) }
    }

    /// フィルタを止めて終了を見届ける。標準入力を閉じ、待っても終わらなければ SIGTERM、さらに SIGKILL。
    /// シグナルはプロセスグループへ送り、本体が終わった後も残った子は SIGKILL で止める
    public func terminate() async {
        closeInput()
        if await !waitForExit(within: ExternalFilterTiming.exitGrace) {
            kill(-pid, SIGTERM)
            if await !waitForExit(within: ExternalFilterTiming.terminateGrace) {
                kill(-pid, SIGKILL)
                _ = await waitForExit(within: ExternalFilterTiming.terminateGrace)
            }
        }
        reapLeader()
    }

    /// フィルタが標準エラーに書いたこと（最初の 4 KB）
    public var stderrText: String { complaints.text }

    /// 終了していれば終了状態（waitpid の status）
    public var status: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus
    }

    private func waitForExit(within limit: Duration) async -> Bool {
        let started = ContinuousClock.now
        while true {
            if reap() { return true }
            if ContinuousClock.now - started >= limit { return false }
            try? await Task.sleep(for: ExternalFilterTiming.reapPoll)
        }
    }

    /// 本体が終了したか。回収（waitpid）はしない。回収するまで pid は再利用されないので、
    /// その間はグループへのシグナルが別のプロセスに届くことがない
    private func reap() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if exitStatus != nil { return true }
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    /// 残った子を止めてから本体を回収する（本体が終わっていなければ何もしない）
    private func reapLeader() {
        guard reap() else { return }
        lock.lock()
        defer { lock.unlock() }
        guard exitStatus == nil else { return }
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            exitStatus = status
        }
    }
}

/// パイプを、呼ばれたぶんだけ読む。
///
/// read はブロックするので専用のキューで行う。読み終えたら（EOF か失敗で）記述子を閉じる。
final class PipeReader: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "com.slack-kingdom.mirne.filter-output")
    private var closed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if !closed { close(descriptor) }
    }

    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            queue.async {
                guard !self.closed else { return continuation.resume(returning: nil) }
                var buffer = [UInt8](repeating: 0, count: ExternalFilterTiming.readChunk)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(self.descriptor, $0.baseAddress, $0.count) }
                    if count > 0 {
                        return continuation.resume(returning: Data(buffer[0..<count]))
                    }
                    if count < 0, errno == EINTR { continue }
                    let failure = count < 0 ? String(cString: strerror(errno)) : nil
                    close(self.descriptor)
                    self.closed = true
                    if let failure {
                        return continuation.resume(throwing: ExternalFilterError.io("read: \(failure)"))
                    }
                    return continuation.resume(returning: nil)
                }
            }
        }
    }
}

public enum ExternalFilterError: Error, LocalizedError, Sendable {
    case launchFailed(String)
    case exited(stderr: String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(detail): "外部フィルタを起動できません: \(detail)"
        case let .exited(stderr): stderr.isEmpty ? "外部フィルタが終了しました" : "外部フィルタが終了しました: \(stderr)"
        case let .io(detail): "外部フィルタとのやり取りに失敗しました: \(detail)"
        }
    }
}
