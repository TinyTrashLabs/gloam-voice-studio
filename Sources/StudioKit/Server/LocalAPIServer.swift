import Hummingbird
import Foundation

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
        let app = Application(
            router: APIRouter.build(deps),
            configuration: .init(address: .hostname(host, port: port)))
        serverTask = Task { try await app.runService() }
    }

    public func stop() async {
        serverTask?.cancel()
        serverTask = nil
    }
}
