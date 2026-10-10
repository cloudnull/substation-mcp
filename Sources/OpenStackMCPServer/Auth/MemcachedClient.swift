import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

// MARK: - Minimal memcached text-protocol client
//
// A deliberately small client for the ONE operation the OAuth replay store
// needs: `add` (NO_OVERWRITE set). No dependency, no binary-protocol support.
// Each call opens a short-lived TCP connection, sends the command, reads the
// one-line reply, and closes — a code is redeemed at most once per exchange,
// so pooling buys nothing.

/// Errors the memcached exchange can produce. `timeout` covers the whole
/// connect + read budget; `protocol` means the server replied with an
/// unexpected terminal line.
public enum MemcachedError: Error, Sendable {
    case connectFailed(String)
    case timeout
    case protocolError(String)
}

/// Thread-safe handoff for a promise that is created on the channel's event
/// loop (inside `channelInitializer`) but is read by the worker thread that
/// runs the exchange. `EventLoopPromise` is not `Sendable`, so the box
/// self-asserts the invariant: the promise is written once on the loop
/// before the handler can settle it, and read only after the bootstrap
/// completes.
final class MemcachedPromiseBox: @unchecked Sendable {
    var promise: EventLoopPromise<String>?
}

/// A single-line memcached response reader. Accumulates inbound fragments
/// until a `\r\n`-terminated status line arrives, then fires its promise
/// (made in `channelActive`, before any data can arrive) exactly once and
/// removes itself from the pipeline. All handler callbacks run on the
/// channel's event loop, so the fragment buffer needs no locking.
final class MemcachedLineHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    /// Must be created on the channel's event loop (see
    /// `MemcachedClient.add`): the handler settles it on that loop and the
    /// worker thread blocks in `futureResult.wait()` — a same-loop promise is
    /// what makes that combination deadlock-free.
    private let promise: EventLoopPromise<String>
    private var pending = ""
    private var settled = false

    init(promise: EventLoopPromise<String>) {
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard !settled else {
            context.fireChannelRead(data)
            return
        }
        let buf = unwrapInboundIn(data)
        let got = buf.getString(at: 0, length: buf.readableBytes) ?? ""
        pending += got
        guard let newline = pending.firstIndex(of: "\n") else {
            if pending.count > 8192 {
                settle(context: context, error: MemcachedError.protocolError("overlong reply"))
            }
            return
        }
        let line = String(pending[..<newline])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            settle(context: context, error: MemcachedError.protocolError("empty reply"))
        } else {
            settle(context: context, reply: line)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        settle(context: context, error: error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !settled {
            settle(context: context, error: MemcachedError.protocolError("connection closed before reply"))
        }
        context.fireChannelInactive()
    }

    private func settle(context: ChannelHandlerContext, reply: String? = nil, error: Error? = nil) {
        guard !settled else { return }
        settled = true
        if let error { promise.fail(error) } else if let reply { promise.succeed(reply) }
        context.pipeline.removeHandler(self).whenComplete { _ in
            context.channel.close()
        }
    }
}

/// The transport seam behind the shared replay store. The production
/// implementation is `MemcachedClient` (real TCP); tests inject an in-process
/// fake so the replay *behavior* is testable without sockets.
public protocol MemcachedTransport: Sendable {
    /// NO_OVERWRITE `add`. Returns `true` when the key was created
    /// (`STORED`), `false` when it already existed (`EXISTS`). Throws on any
    /// failure (connect, timeout, protocol).
    func add(
        key: String,
        value: String,
        ttl: Int,
        host: String,
        port: Int
    ) async throws -> Bool
}

/// A minimal text-protocol memcached client exposing only `add` (the
/// NO_OVERWRITE set the replay store needs). Each call is one short-lived TCP
/// connection: connect (≤ `connectTimeoutSeconds`), send the command, read one
/// line, close — the whole exchange is budgeted by a watchdog task
/// (`connectTimeoutSeconds + readTimeoutSeconds`).
public struct MemcachedClient: Sendable {
    private let logger: Logger
    private let connectTimeoutSeconds: Int
    private let readTimeoutSeconds: Int
    private let elg: MultiThreadedEventLoopGroup

    public init(
        logger: Logger = Logger(label: "memcached-client"),
        connectTimeoutSeconds: Int = 2,
        readTimeoutSeconds: Int = 2
    ) {
        self.logger = logger
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
        self.elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Shut down the client's event-loop group (call at process/test teardown
    /// to avoid NIO "deallocated before shutdown" traps).
    public func shutdown() {
        try? elg.syncShutdownGracefully()
    }

    /// Issue `add <key> 0 <ttl> 0 <nbytes>` + value.
    /// - Returns: `true` when the key was created (`STORED`), `false` when it
    ///   already existed (`EXISTS`).
    /// - Throws: `MemcachedError` on connect failure, timeout, or unexpected
    ///   reply (`NOT_STORED`, `ERROR`, `CLIENT_ERROR`, …).
    public func add(
        key: String,
        value: String,
        ttl: Int,
        host: String,
        port: Int
    ) async throws -> Bool {
        let command = "add \(key) 0 \(ttl) 0 \(value.utf8.count)\r\n\(value)\r\n"
        // Shared handoff between the connect task and the watchdog task:
        // the watchdog schedules the close (on the channel's loop) if the
        // exchange outlives its budget.
        let connected = NIOLockedValueBox<Channel?>(nil)
        let reply: String = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                // No thread-blocking on NIO futures anywhere in this chain:
                // the write future completes on the channel's event loop, so
                // a blocking `.wait()` on it could starve that loop (observed
                // as a read timeout while the test server held the reply).
                // The promise is made ON the channel's loop (inside
                // `channelInitializer`) and settled there; `await`ing it
                // suspends the task, never a loop thread.
                let promiseBox = MemcachedPromiseBox()
                let connectedFuture = ClientBootstrap(group: elg)
                    .channelInitializer { channel in
                        promiseBox.promise = channel.eventLoop.makePromise(of: String.self)
                        return channel.pipeline.addHandler(MemcachedLineHandler(promise: promiseBox.promise!))
                    }
                    .connectTimeout(.seconds(Int64(connectTimeoutSeconds)))
                    .connect(host: host, port: port)
                let writeFuture = connectedFuture.flatMap { channel -> EventLoopFuture<Channel> in
                    channel.writeAndFlush(channel.allocator.buffer(string: command)).map { channel }
                }
                do {
                    let channel = try await writeFuture.get()
                    connected.withLockedValue { $0 = channel }
                    let promise = promiseBox.promise
                    guard let promise else {
                        // Unreachable: the initializer always runs on
                        // connect success.
                        _ = try await channel.close().get()
                        throw MemcachedError.connectFailed("no reply promise")
                    }
                    return try await promise.futureResult.get()
                } catch {
                    // Settle the promise on EVERY failure path so the event
                    // loop never outlives a dangling promise (NIO traps in
                    // syncShutdownGracefully otherwise). A second settle is
                    // a no-op in NIO.
                    if let promise = promiseBox.promise { promise.fail(error) }
                    if let c = connected.withLockedValue({ $0 }) {
                        Task { _ = try? await c.close() }
                    }
                    if let memcachedError = error as? MemcachedError { throw memcachedError }
                    throw MemcachedError.connectFailed(String(describing: error))
                }
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(connectTimeoutSeconds + readTimeoutSeconds) * 1_000_000_000
                )
                // Schedule the close ON the channel's loop (non-blocking):
                // `channelInactive` makes the handler fail the promise, which
                // both prevents the promise-leak trap at loop shutdown and
                // wakes the worker thread if it is blocked in `.wait()`.
                if let c = connected.withLockedValue({ $0 }) {
                    Task { _ = try? await c.close() }
                }
                throw MemcachedError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            _ = try? await group.waitForAll()
            return result
        }
        switch reply {
        case "STORED":
            return true
        case "EXISTS":
            return false
        default:
            throw MemcachedError.protocolError(reply)
        }
    }
}
// Conformance to the transport seam (used by `SharedCodeReplayStore` and
// test fakes); the signature matches `MemcachedTransport.add` exactly.
extension MemcachedClient: MemcachedTransport {}
