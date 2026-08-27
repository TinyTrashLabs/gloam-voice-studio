import Hummingbird
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Owns the optional local API server. Binds 127.0.0.1 by default; the
/// Settings LAN toggle opts into 0.0.0.0 so other devices on the network can
/// reach the API + MCP (no auth — the toggle carries the warning).
public actor LocalAPIServer {
    private let deps: APIDependencies
    private var serverTask: Task<Void, Error>?

    public init(deps: APIDependencies) {
        self.deps = deps
    }

    public var isRunning: Bool { serverTask != nil }

    public func start(port: Int, host: String = "127.0.0.1") async throws {
        guard serverTask == nil else { return }
        // `Application.runService()` runs on Network.framework on macOS,
        // whose NWListener enters a `.waiting` state on a port conflict and
        // keeps silently retrying instead of throwing — awaiting it would
        // hang rather than surface the failure. A plain POSIX bind probe
        // fails fast and deterministically (EADDRINUSE) instead, so do that
        // check first and let a busy port throw here, before Hummingbird
        // ever starts. TOCTOU-vulnerable (the port could be taken between
        // the probe and the real bind), which is an acceptable trade-off for
        // "don't lie about being up" — a rare race just becomes a rare
        // missed error rather than a permanent one.
        try Self.probeBindable(host: host, port: port)
        let app = Application(
            router: APIRouter.build(deps),
            configuration: .init(address: .hostname(host, port: port)))
        serverTask = Task { try await app.runService() }
    }

    public func stop() async {
        guard let task = serverTask else { return }
        serverTask = nil
        task.cancel()
        // Wait for the channel to actually tear down (not just mark
        // cancelled) so a caller that immediately restarts on the same port
        // — the LAN toggle and port-edit flows both do this — doesn't race
        // its own still-closing listener and see a spurious bind failure.
        _ = try? await task.value
    }

    /// Synchronously binds and immediately releases a plain socket on
    /// `host:port` to prove the address is actually free. Throws the
    /// underlying POSIX error (e.g. "Address already in use") on failure.
    private static func probeBindable(host: String, port: Int) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(errno)),
            ])
        }
        defer { close(fd) }
        // SO_REUSEADDR lets the probe bind over a socket of ours left in
        // TIME_WAIT by a just-closed client connection (e.g. a health check
        // right before a restart) — it does NOT let it bind over another
        // process's live listener on the exact same address:port; that
        // still fails regardless of this flag, which is the conflict we're
        // actually trying to detect.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let bindErrno = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(bindErrno), userInfo: [
                NSLocalizedDescriptionKey:
                    "Couldn't bind \(host):\(port) — \(String(cString: strerror(bindErrno)))",
            ])
        }
    }
}
