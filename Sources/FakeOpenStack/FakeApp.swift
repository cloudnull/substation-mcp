import Foundation
import Hummingbird
import Logging
import NIOCore
import HTTPTypes

/// Fake OpenStack cloud: one Hummingbird app with path-dispatched
/// Keystone, Nova, and other service fakes.
public enum FakeApp {
    /// Start a fake app and return a handle.
    @discardableResult
    public static func start() async throws -> FakeHandle {
        let state = FakeState()
        await state.seed()

        let router = Router<BasicRequestContext>()
        let logger = Logger(label: "fake-openstack")

        let hostBox = HostBox()

        KeystoneFake.registerRoutes(router, state: state, baseHost: { hostBox.value })
        NovaFake.registerRoutes(router, state: state)
        NeutronFake.registerRoutes(router, state: state)
        CinderFake.registerRoutes(router, state: state)
        GlanceFake.registerRoutes(router, state: state)
        SwiftFake.registerRoutes(router, state: state)
        BarbicanFake.registerRoutes(router, state: state)
        OctaviaFake.registerRoutes(router, state: state)
        DesignateFake.registerRoutes(router, state: state)

        // Use a continuation to get the port after the server binds
        let portBox = PortBox()

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(port: 0)),
            onServerRunning: { channel in
                if let localAddr = channel.localAddress, let port = localAddr.port {
                    hostBox.value = "http://127.0.0.1:\(port)"
                    portBox.set(port)
                }
            },
            logger: logger
        )

        let runTask = Task {
            try await app.run()
        }

        // Wait for the port
        let port = await portBox.wait()
        guard port > 0 else {
            runTask.cancel()
            throw NSError(domain: "FakeApp", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to bind"])
        }

        let baseURL = "http://127.0.0.1:\(port)"
        await state.setBaseHost(baseURL)

        return FakeHandle(
            runTask: runTask,
            state: state,
            url: URL(string: baseURL)!,
            keystoneURL: URL(string: baseURL + "/keystone/v3")!
        )
    }
}

/// Box to share a mutable string across Sendable boundaries.
final class HostBox: @unchecked Sendable {
    var value: String = "http://127.0.0.1:0"
}

/// Box to share the bound port.
final class PortBox: @unchecked Sendable {
    private var _port: Int = 0
    private var continuation: CheckedContinuation<Int, Never>?

    func set(_ port: Int) {
        _port = port
        continuation?.resume(returning: port)
        continuation = nil
    }

    func wait() async -> Int {
        if _port > 0 { return _port }
        return await withCheckedContinuation { cont in
            continuation = cont
            // Check again in case set() was called before wait()
            if _port > 0 {
                cont.resume(returning: _port)
                continuation = nil
            }
        }
    }
}

/// Handle for a running fake app.
public struct FakeHandle {
    let runTask: Task<Void, Error>
    public let state: FakeState
    public let url: URL
    public let keystoneURL: URL

    public func stop() {
        runTask.cancel()
    }
}
