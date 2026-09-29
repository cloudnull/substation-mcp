import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import Logging
import Atomics
@testable import OpenStackClient

@Suite("Transport")
struct TransportTests {
    // Minimal HTTP/1.1 test server using NIO.
    private final class TestServer: @unchecked Sendable {
        let group: MultiThreadedEventLoopGroup
        var channel: Channel?
        var port: Int = 0
        var handlers: [String: @Sendable (TestServerRequest) async throws -> (Int, String, [(String, String)])] = [:]
        private let lock = NSLock()

        struct TestServerRequest: Sendable {
            let method: String
            let path: String
            let headers: [String: String]
            let body: Data
        }

        init(numThreads: Int = 1) {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: numThreads)
        }

        func addHandler(_ path: String, handler: @escaping @Sendable (TestServerRequest) async throws -> (Int, String, [(String, String)])) {
            lock.lock()
            defer { lock.unlock() }
            handlers[path] = handler
        }

        func start() throws {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    let handler = TestHandler(server: self)
                    return channel.pipeline.addHandler(handler)
                }
            let ch = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
            self.channel = ch
            self.port = ch.localAddress?.port ?? 0
        }

        func stop() {
            try? channel?.close().wait()
            try? group.syncShutdownGracefully()
        }

        var baseURL: URL {
            URL(string: "http://127.0.0.1:\(port)")!
        }

        final class TestHandler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer
            let server: TestServer
            var buffer = Data()
            var done = false

            init(server: TestServer) { self.server = server }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let buf = unwrapInboundIn(data)
                guard let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) else { return }
                buffer.append(contentsOf: bytes)

                // Look for end of headers
                let crlfCrlf: [UInt8] = [0x0d, 0x0a, 0x0d, 0x0a]
                if let headerEnd = range(of: crlfCrlf, in: buffer) {
                    let headerData = buffer[..<headerEnd]
                    let bodyData = Data(buffer[(headerEnd + 4)..<buffer.count])
                    buffer.removeAll(keepingCapacity: true)

                    guard let headerStr = String(data: headerData, encoding: .utf8) else { return }
                    let lines = headerStr.components(separatedBy: "\r\n")
                    guard let requestLine = lines.first else { return }
                    let parts = requestLine.components(separatedBy: " ")
                    guard parts.count >= 2 else { return }
                    let method = parts[0]
                    let path = parts[1]

                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        if let colonIdx = line.firstIndex(of: ":") {
                            let name = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
                            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                            headers[name] = value
                        }
                    }

                    let req = TestServerRequest(method: method, path: path, headers: headers, body: bodyData)
                    let server = self.server
                    let channel = context.channel

                    Task {
                        let handler = server.handlers[path]
                        let (status, responseBody, respHeaders): (Int, String, [(String, String)])
                        do {
                            if let handler {
                                (status, responseBody, respHeaders) = try await handler(req)
                            } else {
                                (status, responseBody, respHeaders) = (404, "not found", [("Content-Type", "text/plain")])
                            }
                        } catch {
                            (status, responseBody, respHeaders) = (500, "server error: \(error)", [("Content-Type", "text/plain")])
                        }

                        let statusText: String
                        switch status {
                        case 200: statusText = "OK"
                        case 400: statusText = "Bad Request"
                        case 403: statusText = "Forbidden"
                        case 404: statusText = "Not Found"
                        case 429: statusText = "Too Many Requests"
                        case 503: statusText = "Service Unavailable"
                        default: statusText = "Error"
                        }

                        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
                        for (name, value) in respHeaders {
                            response += "\(name): \(value)\r\n"
                        }
                        response += "Content-Length: \(responseBody.utf8.count)\r\n"
                        response += "Connection: close\r\n\r\n"
                        let respData = Data(response.utf8) + Data(responseBody.utf8)
                        var outBuf = channel.allocator.buffer(capacity: respData.count)
                        outBuf.writeBytes(respData)
                        try? channel.writeAndFlush(NIOAny(outBuf)).wait()
                    }
                }
            }

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                context.close(promise: nil)
            }

            private func range(of pattern: [UInt8], in data: Data) -> Int? {
                guard pattern.count <= data.count else { return nil }
                for i in 0...(data.count - pattern.count) {
                    var found = true
                    for j in 0..<pattern.count {
                        if data[i + j] != pattern[j] {
                            found = false
                            break
                        }
                    }
                    if found { return i }
                }
                return nil
            }
        }
    }

    private func makeTransport(baseURL: URL, token: String = "tok-123") -> Transport {
        let cloud = CloudEntry(name: "test", authURL: baseURL)
        return Transport(
            cloud: cloud,
            tokenSource: { token },
            maxConnectionsPerHost: 4,
            requestTimeout: .seconds(10),
            logger: Logger(label: "test-transport")
        )
    }

    // MARK: - Headers

    @Test func headersPresentOnRequest() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/headers") { req in
            let json = """
            {"x-auth-token":"\(req.headers["x-auth-token"] ?? "")","user-agent":"\(req.headers["user-agent"] ?? "")","request-id":"\(req.headers["x-openstack-request-id"] ?? "")","accept":"\(req.headers["accept"] ?? "")"}
            """
            return (200, json, [("Content-Type", "application/json")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        let (status, body, requestID) = try await transport.request(
            method: "GET", service: "test", path: "/headers"
        )
        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: String]
        #expect(json["x-auth-token"] == "tok-123")
        #expect(json["user-agent"] == "openstack-mcp/0.1.0")
        #expect(json["accept"] == "application/json")
        let rid = json["request-id"] ?? ""
        #expect(UUID(uuidString: rid) != nil)
        #expect(requestID == rid)
    }

    // MARK: - Retry

    @Test func retriesOn503ForGET() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let attempts = ManagedAtomic(0)
        server.addHandler("/flaky") { _ in
            attempts.wrappingIncrement(by: 1, ordering: .relaxed)
            let n = attempts.load(ordering: .relaxed)
            if n < 3 {
                return (503, "unavailable", [("Content-Type", "text/plain")])
            }
            return (200, #"{"ok":true}"#, [("Content-Type", "application/json")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        let (status, _, _) = try await transport.request(
            method: "GET", service: "test", path: "/flaky"
        )
        #expect(status == 200)
        #expect(attempts.load(ordering: .relaxed) == 3)
    }

    @Test func noRetryOnPOST() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let attempts = ManagedAtomic(0)
        server.addHandler("/no-retry") { _ in
            attempts.wrappingIncrement(by: 1, ordering: .relaxed)
            return (503, "unavailable", [("Content-Type", "text/plain")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        do {
            _ = try await transport.request(
                method: "POST", service: "test", path: "/no-retry", body: .init("{}".utf8)
            )
            #expect(false, "should have thrown")
        } catch {
            #expect(attempts.load(ordering: .relaxed) == 1)
        }
    }

    // MARK: - Error normalization

    @Test func normalizesNovaError() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/error-nova") { _ in
            let body = #"{"itemNotFound": {"message": "Instance not found."}}"#
            return (404, body, [("Content-Type", "application/json")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        do {
            _ = try await transport.request(method: "GET", service: "nova", path: "/error-nova")
            #expect(false, "should have thrown")
        } catch let err as OpenStackError {
            #expect(err.status == 404)
            #expect(err.code == "itemNotFound")
            #expect(err.message == "Instance not found.")
            #expect(err.service == "nova")
        }
    }

    @Test func normalizesGlancePlainText() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/glance-missing") { _ in
            return (400, "Image not found", [("Content-Type", "text/plain")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        do {
            _ = try await transport.request(method: "GET", service: "glance", path: "/glance-missing")
            #expect(false, "should have thrown")
        } catch let err as OpenStackError {
            #expect(err.status == 400)
            #expect(err.code == nil)
            #expect(err.message == "Image not found")
            #expect(err.service == "glance")
        }
    }

    // MARK: - Timeout

    @Test func timeoutOnSlowEndpoint() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/slow") { _ in
            try await Task.sleep(for: .seconds(2))
            return (200, "late", [("Content-Type", "text/plain")])
        }

        // Use a transport with a 300ms read timeout so the 2s endpoint times out
        let cloud = CloudEntry(name: "test", authURL: server.baseURL)
        let transport = Transport(
            cloud: cloud,
            tokenSource: { "tok-123" },
            maxConnectionsPerHost: 4,
            requestTimeout: .milliseconds(300),
            logger: Logger(label: "test-transport")
        )
        defer { transport.syncShutdown() }
        do {
            _ = try await transport.request(
                method: "GET", service: "test", path: "/slow"
            )
            #expect(false, "should have timed out")
        } catch let err as OpenStackError {
            #expect(err.retriable == true)
            #expect(err.status == 0)
        }
    }
}
