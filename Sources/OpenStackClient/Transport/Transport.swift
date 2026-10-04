import Foundation
import AsyncHTTPClient
import NIOPosix
import NIOSSL
import Logging
import NIOCore
import CoreMetrics

public actor Transport {
    private let client: HTTPClient
    private let eventLoopGroup: MultiThreadedEventLoopGroup?
    private let baseURL: URL
    private let tokenSource: @Sendable () async throws -> String
    private let requestTimeout: Duration
    private let logger: Logger
    private let maxRetries: Int = 3
    private let backoffCapSeconds: Double = 60.0

    public init(
        cloud: CloudEntry,
        tokenSource: @escaping @Sendable () async throws -> String,
        maxConnectionsPerHost: Int = 16,
        requestTimeout: Duration = .seconds(60),
        logger: Logger
    ) {
        self.tokenSource = tokenSource
        self.requestTimeout = requestTimeout
        self.logger = logger

        // An explicit MultiThreadedEventLoopGroup for the AsyncHTTPClient.
        // The default `.createNew` provider was observed firing
        // HTTPClientError.connectTimeout reaching in-cluster Keystone on a
        // Kube-OVN pod while curl in the same netns connected in ~8 ms — the
        // client's event-loop connect-completion was not posting in time.
        // A named, multi-threaded ELG completes the connect reliably.
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        self.eventLoopGroup = elg

        guard let baseURL = cloud.authURL else {
            self.client = HTTPClient(eventLoopGroupProvider: .shared(elg))
            self.baseURL = URL(string: "http://localhost:9000")!
            return
        }

        self.baseURL = baseURL

        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        if cloud.verify == false {
            tlsConfig.certificateVerification = .none
        }
        if let cacert = cloud.cacert,
           let pemData = cacert.data(using: .utf8),
           !pemData.isEmpty {
            // TODO: load PEM certs via NIOSSL once API confirmed
            logger.info("Transport: cacert configured for cloud '\(cloud.name)' (PEM loading TBD)")
        }

        let timeoutSeconds = Int64(Double(requestTimeout.components.seconds)
            + Double(requestTimeout.components.attoseconds) / 1e18)

        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(elg),
            configuration: .init(
                tlsConfiguration: tlsConfig,
                // Follow redirects: some service version documents (e.g. Cinder's
                // `/v3`) 302-redirect to the trailing-slash form (`/v3/`) that
                // serves the actual document. Data-plane OpenStack calls do not
                // redirect, so this is safe for the whole client.
                redirectConfiguration: .follow(configuration: .init(
                    max: 3,
                    allowCycles: false,
                    retainHTTPMethodAndBodyOn301: false,
                    retainHTTPMethodAndBodyOn302: false
                )),
                timeout: .init(
                    // 30 s connect: in some CNI/Kube-OVN pod networks the
                    // kernel completes the TCP handshake but NIO's event-loop
                    // connect-completion is slow to post; 10 s fired
                    // connectTimeout while the connection was actually usable.
                    connect: .seconds(30),
                    read: .seconds(max(timeoutSeconds, 1))
                ),
                connectionPool: .init(
                    idleTimeout: .seconds(60),
                    // `0` (or a negative value, e.g. from a "unlimited" config
                    // default) would tell AsyncHTTPClient to open ZERO new
                    // HTTP/1.1 connections to the host — every request then
                    // waits forever for a connection that is never created and
                    // times out (HTTPClientError.connectTimeout with no SYN
                    // ever on the wire). Clamp to a sensible positive limit.
                    concurrentHTTP1ConnectionsPerHostSoftLimit: max(maxConnectionsPerHost, 1)
                )
            )
        )
        self.client = httpClient
    }

    public func shutdown() {
        try? client.syncShutdown()
        // Shut down the shared ELG only after the client has drained its
        // connections back onto it.
        try? eventLoopGroup?.syncShutdownGracefully()
    }

    nonisolated public func syncShutdown() {
        try? client.syncShutdown()
        try? eventLoopGroup?.syncShutdownGracefully()
    }

    // Safety net: if a Transport is released without an explicit shutdown (a
    // leak), AsyncHTTPClient traps in its own deinit ("Client not shut down
    // before the deinit"), which kills the whole process — including an opt-in
    // test runner. Draining here turns a hard crash into a logged leak so the
    // underlying bug surfaces as an error, not a SIGTRAP.
    deinit {
        try? client.syncShutdown()
        try? eventLoopGroup?.syncShutdownGracefully()
    }

    public func request(
        method: String,
        service: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        /// The token to send as `X-Auth-Token`.
        /// - `nil` (default): use the standing token source.
        /// - `""`: send **no** `X-Auth-Token` header (anonymous request, e.g.
        ///   token minting at `/v3/auth/tokens` with a credential body).
        /// - non-empty: send that token (e.g. token validation).
        tokenOverride: String? = nil,
        extraHeaders: [(String, String)] = [],
        timeoutOverride: Duration? = nil,
        /// When set, the request is sent to this base URL instead of the
        /// cloud's `authURL`. Used for per-service endpoint resolution from the
        /// token's service catalog on multi-endpoint clouds (e.g. Rackspace,
        /// where nova/glance/neutron each live on separate hosts). `path` is
        /// appended to this base, so callers pass a path relative to the
        /// service root.
        overrideBase: URL? = nil,
        /// When true, 3xx responses (e.g. HTTP 300 Multiple Choices) are
        /// returned to the caller instead of being normalized into an error.
        /// Service version documents (cinder, glance) legitimately return 300,
        /// so the negotiator uses this to read the body.
        tolerate3xx: Bool = false
    ) async throws -> (status: Int, body: Data, requestID: String?) {
        let requestID = UUID().uuidString
        let token: String?
        if let tokenOverride {
            token = tokenOverride
        } else {
            token = try await tokenSource()
        }

        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let effectiveBase = overrideBase ?? baseURL
        // An empty path targets the base URL directly (no trailing slash), so
        // version-doc fetches at the service root hit `base/` without a slash.
        var url = cleanPath.isEmpty ? effectiveBase : effectiveBase.appendingPathComponent(cleanPath)
        if !query.isEmpty {
            if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                comps.queryItems = query
                url = comps.url ?? url
            }
        }

        var req = try HTTPClient.Request(url: url.absoluteString, method: .init(rawValue: method))
        if let token, !token.isEmpty {
            req.headers.add(name: "X-Auth-Token", value: token)
            // Send X-Subject-Token ONLY on the whoami endpoint
            // (GET /v3/auth/tokens). Some Keystone versions (e.g. 3.14) honor
            // the token on whoami only when it is also sent as X-Subject-Token.
            //
            // It must NOT be sent on any other request: X-Subject-Token names
            // the token that was just minted within the same exchange, and is
            // tied to that minting session. Reusing a pre-minted / standing
            // token (e.g. one from OS_AUTH_TOKEN, or the provisioner's
            // admin/service-user tokens) as X-Subject-Token makes Keystone
            // reject the request — observed as spurious 400s/403s and empty
            // responses on the Genestack/RDO in-cluster Keystone. Every
            // non-whoami request (catalog writes, identity writes, service
            // calls) authenticates with X-Auth-Token alone.
            let isWhoami = method.uppercased() == "GET" && cleanPath == "v3/auth/tokens"
            if isWhoami {
                req.headers.add(name: "X-Subject-Token", value: token)
            }
        }
        req.headers.add(name: "Accept", value: "application/json")
        req.headers.add(name: "Content-Type", value: "application/json")
        req.headers.add(name: "User-Agent", value: "substation-mcp/\(openStackClientVersion)")
        req.headers.add(name: "X-OpenStack-Request-Id", value: requestID)
        for (name, value) in extraHeaders {
            req.headers.add(name: name, value: value)
        }
        if let body {
            req.body = .bytes([UInt8](body))
        }

        let isRetryable = (method == "GET" || method == "HEAD" || method == "DELETE")

        var attempt = 0
        let start = DispatchTime.now()

        while true {
            attempt += 1
            do {
                let response = try await client.execute(request: req).get()
                let bodyData = response.body.map { Data($0.readableBytesView) } ?? Data()
                let status = Int(response.status.code)
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
                OSMetrics.openstackRequest(service: service, method: method, status: status)
                OSMetrics.openstackRequestDuration(service: service, seconds: seconds)

                if response.status.code >= 200 && response.status.code < 300
                    || (tolerate3xx && response.status.code >= 300 && response.status.code < 400)
                {
                    return (status, bodyData, requestID)
                }

                let isRetriableStatus = status == 429
                    || status == 502
                    || status == 503
                    || status == 504

                if isRetriableStatus && isRetryable && attempt < maxRetries {
                    let retryAfter = response.headers.first(name: "Retry-After").flatMap {
                        Double($0)
                    }
                    let delaySeconds: Double
                    if let ra = retryAfter {
                        delaySeconds = ra
                    } else {
                        let exp = pow(2.0, Double(attempt - 1))
                        let jitter = Double.random(in: 0...0.5)
                        delaySeconds = min(exp + jitter, backoffCapSeconds)
                    }
                    logger.debug("Transport: retry \(attempt) for \(service) \(method) \(path) after \(status)")
                    try await Task.sleep(for: .seconds(delaySeconds))
                    continue
                }

                let err = OpenStackError.normalize(
                    body: bodyData,
                    status: status,
                    service: service,
                    requestID: requestID,
                    hasAccessRules: false
                )
                throw err

            } catch let e as OpenStackError {
                throw e
            } catch let e {
                if isRetryable && attempt < maxRetries {
                    let exp = pow(2.0, Double(attempt - 1))
                    let jitter = Double.random(in: 0...0.5)
                    let delaySeconds = min(exp + jitter, backoffCapSeconds)
                    try await Task.sleep(for: .seconds(delaySeconds))
                    continue
                }
                throw OpenStackError(
                    service: service,
                    status: 0,
                    message: "Transport error: \(e)",
                    requestID: requestID,
                    retriable: isRetryable
                )
            }
        }
    }
}
