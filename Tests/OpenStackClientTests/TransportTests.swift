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
