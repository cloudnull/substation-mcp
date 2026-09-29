import Foundation
import AsyncHTTPClient
import NIOSSL
import Logging
import NIOCore

public actor Transport {
    private let client: HTTPClient
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

        guard let baseURL = cloud.authURL else {
            self.client = HTTPClient(eventLoopGroupProvider: .createNew)
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
            configuration: .init(
                tlsConfiguration: tlsConfig,
                timeout: .init(
                    connect: .seconds(10),
                    read: .seconds(max(timeoutSeconds, 1))
                ),
                connectionPool: .init(
                    idleTimeout: .seconds(60),
                    concurrentHTTP1ConnectionsPerHostSoftLimit: maxConnectionsPerHost
                )
            )
        )
        self.client = httpClient
    }

    public func shutdown() {
        try? client.syncShutdown()
    }

    nonisolated public func syncShutdown() {
        try? client.syncShutdown()
    }

    public func request(
        method: String,
        service: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        tokenOverride: String? = nil,
        extraHeaders: [(String, String)] = [],
        timeoutOverride: Duration? = nil
    ) async throws -> (status: Int, body: Data, requestID: String?) {
        let requestID = UUID().uuidString
        let token: String
        if let tokenOverride {
            token = tokenOverride
        } else {
            token = try await tokenSource()
        }

        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var url = baseURL.appendingPathComponent(cleanPath)
        if !query.isEmpty {
            if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                comps.queryItems = query
                url = comps.url ?? url
            }
        }

        var req = try HTTPClient.Request(url: url.absoluteString, method: .init(rawValue: method))
        req.headers.add(name: "X-Auth-Token", value: token)
        req.headers.add(name: "Accept", value: "application/json")
        req.headers.add(name: "Content-Type", value: "application/json")
        req.headers.add(name: "User-Agent", value: "openstack-mcp/\(openStackClientVersion)")
        req.headers.add(name: "X-OpenStack-Request-Id", value: requestID)
        for (name, value) in extraHeaders {
            req.headers.add(name: name, value: value)
        }
        if let body {
            req.body = .bytes([UInt8](body))
        }

        let isRetryable = (method == "GET" || method == "HEAD" || method == "DELETE")

        var attempt = 0

        while true {
            attempt += 1
            do {
                let response = try await client.execute(request: req).get()
                let bodyData = response.body.map { Data($0.readableBytesView) } ?? Data()

                if response.status.code >= 200 && response.status.code < 300 {
                    return (Int(response.status.code), bodyData, requestID)
                }

                let status = Int(response.status.code)
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
