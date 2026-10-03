import Foundation
import MCP
import Logging

/// Per-session protocol state only.
///
/// Holds the SDK `Server` + transport and timing metadata. It deliberately
/// stores **no principal, no fingerprint, no credential** (spec §7.1): identity
/// is per-request, validated on every call, and never persisted here.
public struct MCPSession: @unchecked Sendable {
    public let server: Server
    public let transport: StatefulHTTPServerTransport
    public let sessionID: String
    public var lastAccessedAt: Date
    public let createdAt: Date

    public init(
        server: Server,
        transport: StatefulHTTPServerTransport,
        sessionID: String,
        lastAccessedAt: Date,
        createdAt: Date
    ) {
        self.server = server
        self.transport = transport
        self.sessionID = sessionID
        self.lastAccessedAt = lastAccessedAt
        self.createdAt = createdAt
    }

    /// Tear down the session: stop the `Server` and disconnect its transport.
    ///
    /// Both `Server.stop()` and `StatefulHTTPServerTransport.terminate()` are
    /// idempotent, so calling this more than once (e.g. DELETE plus idle
    /// eviction) is safe.
    public func disconnect() async {
        await server.stop()
    }
}

/// Actor-isolated store of live MCP sessions, keyed by `Mcp-Session-Id`.
///
/// `terminate` calls the `terminated` callback so the caller (Task 18) can
/// zeroize any login-minted token bound to that session. `evictExpired` drops
/// sessions idle beyond `idleTTL`; a background cleanup task runs it on a fixed
/// interval.
public actor SessionRegistry {
    private var sessions: [String: MCPSession]
    private let terminated: @Sendable (String) -> Void
    private let idleTTL: TimeInterval
    private let maxLifetime: TimeInterval
    private let cleanupInterval: Duration
    private let logger: Logger
    private var cleanupTask: Task<Void, Never>?

    /// Create an empty registry and start the background cleanup task.
    public init(
        idleTTL: TimeInterval,
        maxLifetime: TimeInterval = 86_400,
        cleanupInterval: Duration = .seconds(60),
        terminated: @escaping @Sendable (String) -> Void = { _ in },
        logger: Logger
    ) {
        self.sessions = [:]
        self.terminated = terminated
        self.idleTTL = idleTTL
        self.maxLifetime = maxLifetime
        self.cleanupInterval = cleanupInterval
        self.logger = logger
        // The actor `init` is nonisolated, so kick off the background cleanup by
        // awaiting the (fully initialized) actor from a spawned task.
        Task { [weak self] in
            await self?.startCleanup()
        }
    }

    /// Start the periodic idle-session eviction loop (idempotent).
    public func startCleanup() {
        guard cleanupTask == nil else { return }
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    _ = try await Task.sleep(for: self.cleanupInterval)
                } catch {
                    break
                }
                _ = await self.evictExpired(now: Date())
            }
        }
    }

    deinit {
        cleanupTask?.cancel()
    }

    public func get(_ id: String) -> MCPSession? { sessions[id] }

    @discardableResult
    public func register(_ session: MCPSession) -> MCPSession {
        sessions[session.sessionID] = session
        return session
    }

    /// Remove a session and fire the `terminated` callback. Returns the removed
    /// session so the caller can disconnect it, or `nil` if unknown.
    public func terminate(_ id: String) -> MCPSession? {
        guard let session = sessions.removeValue(forKey: id) else { return nil }
        terminated(id)
        return session
    }

    /// Touch a session's last-access time.
    public func touch(_ id: String) {
        guard var session = sessions[id] else { return }
        session.lastAccessedAt = Date()
        sessions[id] = session
    }

    /// The number of live sessions (for tests and `osmcp_sessions_active`).
    public var count: Int { sessions.count }

    /// Drop sessions that are idle longer than `idleTTL` OR older than
    /// `maxLifetime` (spec §12: a session that survives its idle TTL but not its
    /// max lifetime is still evicted). Returns the ids evicted.
    public func evictExpired(now: Date) -> [String] {
        let idleCutoff = now.addingTimeInterval(-idleTTL)
        let lifetimeCutoff = now.addingTimeInterval(-maxLifetime)
        let evicted = sessions
            .filter { $0.value.lastAccessedAt < idleCutoff || $0.value.createdAt < lifetimeCutoff }
            .map(\.key)
        for id in evicted {
            sessions.removeValue(forKey: id)
            terminated(id)
            logger.info("Session evicted", metadata: ["sessionID": "\(id)"])
        }
        return evicted
    }

    /// Stop the cleanup task and close all sessions (for app shutdown).
    public func shutdown() async {
        cleanupTask?.cancel()
        cleanupTask = nil
        for (id, session) in sessions {
            _ = terminate(id)
            await session.disconnect()
        }
        sessions.removeAll()
    }
}
