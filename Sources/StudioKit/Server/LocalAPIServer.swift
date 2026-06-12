import Hummingbird
import Foundation

/// Owns the optional loopback API server. v1 binds 127.0.0.1 only — there is
/// deliberately no way to bind wider (spec: developer feature, off by default).
public actor LocalAPIServer {
    private let deps: APIDependencies
    private var serverTask: Task<Void, Error>?

    public init(deps: APIDependencies) {
        self.deps = deps
    }

    public var isRunning: Bool { serverTask != nil }

    public func start(port: Int) async throws {
        guard serverTask == nil else { return }
        let app = Application(
            router: APIRouter.build(deps),
            configuration: .init(address: .hostname("127.0.0.1", port: port)))
        serverTask = Task { try await app.runService() }
    }

    public func stop() async {
        serverTask?.cancel()
        serverTask = nil
    }
}
