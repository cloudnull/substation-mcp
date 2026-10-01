import Foundation
import HTTPTypes
import Logging
import NIOCore
import OpenStackClient

// MARK: - Catalog registration (spec §11.3 `register-catalog`)

/// The catalog entry the `register-catalog` subcommand installs: one service
/// of type `mcp` with public/internal/admin endpoints at the configured MCP
/// URL. The core here is pure against a `Transport`; the CLI shim resolves
/// the cloud and builds the transport (spec §11.3).
public struct CatalogRegistrar {
    /// Result of registering the catalog. `serviceID`/`endpointIDs` identify
    /// what was created or reused so the operator can verify.
    public struct Result: Sendable {
        public let serviceID: String
        public let endpointIDs: [String]
        /// Endpoints that already existed and were reused (not created).
        public let reusedEndpointIDs: [String]
    }

    /// The service type used for the MCP catalog entry.
    public static let serviceType = "mcp"
    /// Interface roles, in the order they are ensured.
    public static let interfaces: [String] = ["public", "internal", "admin"]

    private let transport: Transport
    private let region: String
    private let publicURL: String
    /// Admin token used for the identity write calls (X-Auth-Token).
    private let adminToken: String
    private let logger: Logger

    public init(
        transport: Transport,
        region: String,
        publicURL: String,
        adminToken: String,
        logger: Logger = Logger(label: "catalog-registrar")
    ) {
        self.transport = transport
        self.region = region
        self.publicURL = publicURL
        self.adminToken = adminToken
        self.logger = logger
    }

    /// Ensure the `mcp` service and its public/internal/admin endpoints exist
    /// (idempotent: reuse existing entries, create missing ones). The admin
    /// token is used for all identity write calls.
    public func ensureCatalog() async throws -> Result {
        let serviceID = try await ensureService()
        var endpointIDs: [String] = []
        var reused: [String] = []
        for interface in Self.interfaces {
            let (id, created) = try await ensureEndpoint(
                serviceID: serviceID,
                interface: interface,
                url: publicURL
            )
            endpointIDs.append(id)
            if !created { reused.append(id) }
        }
        return Result(serviceID: serviceID, endpointIDs: endpointIDs, reusedEndpointIDs: reused)
    }

    // MARK: - service

    /// Find (by type `mcp`) or create the catalog service.
    private func ensureService() async throws -> String {
        struct Service: Decodable {
            let id: String
            let type: String?
            let name: String?
        }
        let (status, body, _) = try await transport.request(
            method: "GET", service: "identity",
            path: "/keystone/v3/services",
            query: [URLQueryItem(name: "limit", value: "1000")],
            tokenOverride: adminToken
        )
        guard status == 200 else {
            throw CatalogRegistrarError.identityHTTP(status)
        }
        struct ServiceList: Decodable { let services: [Service] }
        guard let list = try? JSONDecoder().decode(ServiceList.self, from: body) else {
            throw CatalogRegistrarError.decode
        }
        if let existing = list.services.first(where: { $0.type == Self.serviceType }) {
            return existing.id
        }
        let createBody = """
        {"service":{"type":"\(Self.serviceType)","name":"mcp","description":"Model Context Protocol endpoint for the OpenStack cloud"}}
        """
        let (cStatus, cBody, _) = try await transport.request(
            method: "POST", service: "identity",
            path: "/keystone/v3/services",
            body: Data(createBody.utf8),
            tokenOverride: adminToken
        )
        guard cStatus == 201 else {
            throw CatalogRegistrarError.identityHTTP(cStatus)
        }
        struct CreatedService: Decodable { let id: String; let type: String? }
        struct ServiceResp: Decodable { let service: CreatedService }
        guard let resp = try? JSONDecoder().decode(ServiceResp.self, from: cBody) else {
            throw CatalogRegistrarError.decode
        }
        logger.info("Created mcp catalog service", metadata: ["id": .string(resp.service.id)])
        return resp.service.id
    }

    // MARK: - endpoints

    /// Find (by service, interface, region) or create the endpoint.
    private func ensureEndpoint(serviceID: String, interface: String, url: String) async throws -> (id: String, created: Bool) {
        struct Endpoint: Decodable {
            let id: String
            let service_id: String?
            let interface: String?
            let region_id: String?
        }
        let (status, body, _) = try await transport.request(
            method: "GET", service: "identity",
            path: "/keystone/v3/endpoints",
            query: [
                URLQueryItem(name: "service_id", value: serviceID),
                URLQueryItem(name: "limit", value: "1000"),
            ],
            tokenOverride: adminToken
        )
        guard status == 200 else {
            throw CatalogRegistrarError.identityHTTP(status)
        }
        struct EndpointList: Decodable { let endpoints: [Endpoint] }
        var existing: [String: Endpoint] = [:]
        if let list = try? JSONDecoder().decode(EndpointList.self, from: body) {
            for e in list.endpoints {
                guard let sid = e.service_id else { continue }
                existing["\(sid)|\(e.interface ?? "")|\(e.region_id ?? "")"] = e
            }
        }
        if let found = existing["\(serviceID)|\(interface)|\(region)"] {
            return (found.id, false)
        }
        let createBody = """
        {"endpoint":{"interface":"\(interface)","region_id":"\(region)","url":"\(url)"}}
        """
        let (cStatus, cBody, _) = try await transport.request(
            method: "POST", service: "identity",
            path: "/keystone/v3/services/\(serviceID)/endpoints",
            body: Data(createBody.utf8),
            tokenOverride: adminToken
        )
        guard cStatus == 201 else {
            throw CatalogRegistrarError.identityHTTP(cStatus)
        }
        struct CreatedEndpoint: Decodable { let id: String }
        struct EndpointResp: Decodable { let endpoint: CreatedEndpoint }
        guard let resp = try? JSONDecoder().decode(EndpointResp.self, from: cBody) else {
            throw CatalogRegistrarError.decode
        }
        logger.info("Created mcp catalog endpoint", metadata: [
            "interface": .string(interface),
            "region": .string(region),
            "id": .string(resp.endpoint.id),
        ])
        return (resp.endpoint.id, true)
    }
}

public enum CatalogRegistrarError: Error {
    case identityHTTP(Int)
    case decode
}
