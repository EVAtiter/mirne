import Foundation

/// coaxd の HTTP ソケットの場所。
///
/// coax の `pkg/host/client.go`（`DefaultAddress`・`runtimeDir`）と同じ規則で決める。
/// クライアントはまだ話したことのないデーモンを探すので、デーモンに教わるのではなく
/// 両者が同じ規則で場所を割り出す、という coax の考え方に合わせている。
public enum CoaxSocket {
    /// macOS の `sockaddr_un.sun_path` の長さ（終端の NUL を含む）。
    /// これ以上長いパスは `connect` が `EINVAL` を返すだけで原因が分からないので、先に調べる。
    public static let maxPathLength = 104

    /// ソケットのファイル名（coaxd が開く唯一のソケット）
    static let fileName = "http.sock"

    /// 既定のソケットのパス。
    ///
    /// 優先順は `COAXD_SOCKET`（ソケットそのもの）→ `COAXD_SOCKET_DIR`（ディレクトリ）→
    /// `$TMPDIR/coaxd` → `/tmp/coaxd-<UID>`。
    /// coax の `COAX_HOST` は TCP のアドレスも取りうるので、ここでは扱わない（Unix ソケットだけを使う）。
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let socket = environment["COAXD_SOCKET"], !socket.isEmpty {
            return socket
        }
        return (directory(environment: environment) as NSString).appendingPathComponent(fileName)
    }

    /// coaxd がソケットを置くディレクトリ（`coax pcsc` のソケットも同じ場所に置かれる）
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let named = environment["COAXD_SOCKET_DIR"], !named.isEmpty {
            return named
        }
        if let base = environment["TMPDIR"], !base.isEmpty {
            return (base as NSString).appendingPathComponent("coaxd")
        }
        return "/tmp/coaxd-\(getuid())"
    }

    /// パスがソケットとして使える長さかを調べる。
    public static func validate(_ path: String) throws {
        let length = path.utf8.count
        if length >= maxPathLength {
            throw CoaxError.socketPathTooLong(path: path, length: length, limit: maxPathLength - 1)
        }
    }
}
