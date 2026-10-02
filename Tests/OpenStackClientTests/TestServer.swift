import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// Shared NIO-based HTTP test server.
final class TestServer: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    var channel: Channel?
    var port: Int = 0
    var handlers: [String: @Sendable (TestServerRequest) async throws -> (Int, String, [(String, String)])] = [:]
    private let lock = NSLock()

    struct TestServerRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        /// The raw request-header block (newline-joined "Name: value" lines).
        /// Preserved so tests can count DUPLICATE headers, which the collapsed
        /// `headers` dict above silently drops.
        let rawHeaders: String
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

        init(server: TestServer) { self.server = server }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buf = unwrapInboundIn(data)
            guard let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) else { return }
            buffer.append(contentsOf: bytes)

            let crlfCrlf: [UInt8] = [0x0d, 0x0a, 0x0d, 0x0a]
            if let headerEnd = findRange(of: crlfCrlf, in: buffer) {
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
                let rawHeaders = lines.dropFirst().joined(separator: "\n")

                let req = TestServerRequest(method: method, path: path, headers: headers, rawHeaders: rawHeaders, body: bodyData)
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
                    case 201: statusText = "Created"
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

        private func findRange(of pattern: [UInt8], in data: Data) -> Int? {
            guard pattern.count <= data.count else { return nil }
            for i in 0...(data.count - pattern.count) {
                var found = true
                for j in 0..<pattern.count {
                    if data[i + j] != pattern[j] { found = false; break }
                }
                if found { return i }
            }
            return nil
        }
    }
}
