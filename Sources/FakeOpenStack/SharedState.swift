import Foundation

/// In-memory state for the fake OpenStack cloud.
/// Seeded with 2 regions, standard flavors, one image, default security group,
/// one external network + subnet + router, and seeded credentials.
public actor FakeState {
    // MARK: - Credentials

    public struct FakeCredential: Sendable {
        public let id: String
        public let name: String
        public let secret: String
        public let projectID: String
        public let roles: [String]
        public let method: AuthMethod
        public let userID: String
        public let userName: String
        public let domain: String

        public enum AuthMethod: Sendable {
            case applicationCredential
            case password
        }
    }

    // MARK: - Token store

    public struct FakeToken: Sendable {
        public let id: String
        public let projectID: String
        public let projectName: String
        public let domainID: String
        public let domainName: String
        public let userID: String
        public let userName: String
        public let userDomain: String
        public let roles: [String]
        public let expiresAt: Date
    }

    // MARK: - Resources

    public struct FakeServer: Sendable, Identifiable {
        public let id: String
        public var name: String
        public var status: String
        public var flavorID: String
        public var flavorName: String
        public var imageID: String?
        public var projectID: String
        public var region: String
        public var addresses: [String: [String: String]]
        public var keyName: String?
        public var securityGroups: [String: String]
        public var metadata: [String: String]
        public var created: Date
        public var updated: Date?

        public init(
            id: String,
            name: String,
            status: String = "ACTIVE",
            flavorID: String = "1",
            flavorName: String = "m1.small",
            imageID: String? = nil,
            projectID: String,
            region: String = "RegionOne",
            addresses: [String: [String: String]] = [:],
            keyName: String? = nil,
            securityGroups: [String: String] = [:],
            metadata: [String: String] = [:]
        ) {
            self.id = id
            self.name = name
            self.status = status
            self.flavorID = flavorID
            self.flavorName = flavorName
            self.imageID = imageID
            self.projectID = projectID
            self.region = region
            self.addresses = addresses
            self.keyName = keyName
            self.securityGroups = securityGroups
            self.metadata = metadata
            self.created = Date()
            self.updated = nil
        }
    }

    public struct FakeFlavor: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let vcpus: Int
        public let ram: Int
        public let disk: Int
    }

    public struct FakeNetwork: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let projectID: String
        public let region: String
        public var routerExternal: Bool
        public var status: String
        public var subnets: [String]
    }

    public struct FakeSubnet: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let networkID: String
        public let projectID: String
        public let cidr: String
        public let gatewayIP: String?
    }

    public struct FakeRouter: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let projectID: String
        public let externalNetworkID: String?
        public var status: String
    }

    public struct FakeSecurityGroup: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let projectID: String
    }

    // MARK: - Storage

    public private(set) var credentials: [FakeCredential] = []
    public private(set) var tokens: [String: FakeToken] = [:]
    public private(set) var servers: [FakeServer] = []
    public private(set) var flavors: [FakeFlavor] = []
    public private(set) var networks: [FakeNetwork] = []
    public private(set) var subnets: [FakeSubnet] = []
    public private(set) var routers: [FakeRouter] = []
    public private(set) var securityGroups: [FakeSecurityGroup] = []

    private var serverIDCounter = 0
    private var tokenIDCounter = 0
    private var _baseHost: String = "http://127.0.0.1:0"

    public var baseHost: String { _baseHost }
    public func setBaseHost(_ host: String) { _baseHost = host }

    public init() {}

    // MARK: - Seeding

    /// Seed the fake state with default data.
    public func seed() {
        // Flavors
        flavors = [
            FakeFlavor(id: "1", name: "m1.small", vcpus: 1, ram: 2048, disk: 20),
            FakeFlavor(id: "2", name: "m1.large", vcpus: 2, ram: 8192, disk: 40),
            FakeFlavor(id: "3", name: "m1.xlarge", vcpus: 4, ram: 16384, disk: 80)
        ]

        // Networks
        networks = [
            FakeNetwork(id: "net-ext", name: "ext-net", projectID: "proj-one", region: "RegionOne", routerExternal: true, status: "ACTIVE", subnets: ["subnet-ext"]),
            FakeNetwork(id: "net-int", name: "int-net", projectID: "proj-one", region: "RegionOne", routerExternal: false, status: "ACTIVE", subnets: ["subnet-int"]),
            FakeNetwork(id: "net-two", name: "int-net-2", projectID: "proj-two", region: "RegionOne", routerExternal: false, status: "ACTIVE", subnets: ["subnet-two"])
        ]

        // Subnets
        subnets = [
            FakeSubnet(id: "subnet-ext", name: "subnet-ext", networkID: "net-ext", projectID: "proj-one", cidr: "10.0.0.0/24", gatewayIP: "10.0.0.1"),
            FakeSubnet(id: "subnet-int", name: "subnet-int", networkID: "net-int", projectID: "proj-one", cidr: "192.168.1.0/24", gatewayIP: "192.168.1.1"),
            FakeSubnet(id: "subnet-two", name: "subnet-two", networkID: "net-two", projectID: "proj-two", cidr: "192.168.2.0/24", gatewayIP: "192.168.2.1")
        ]

        // Routers
        routers = [
            FakeRouter(id: "router-1", name: "router-1", projectID: "proj-one", externalNetworkID: "net-ext", status: "ACTIVE")
        ]

        // Security groups
        securityGroups = [
            FakeSecurityGroup(id: "sg-default", name: "default", projectID: "proj-one"),
            FakeSecurityGroup(id: "sg-default-two", name: "default", projectID: "proj-two")
        ]

        // Credentials
        credentials = [
            FakeCredential(
                id: "fake-cred-admin",
                name: "fake-cred-admin",
                secret: "secret-admin",
                projectID: "proj-one",
                roles: ["admin"],
                method: .applicationCredential,
                userID: "user-admin",
                userName: "admin",
                domain: "default"
            ),
            FakeCredential(
                id: "fake-cred-ro",
                name: "fake-cred-ro",
                secret: "secret-ro",
                projectID: "proj-one",
                roles: ["member", "_member_"],
                method: .applicationCredential,
                userID: "user-ro",
                userName: "readonly",
                domain: "default"
            ),
            FakeCredential(
                id: "fake-cred-two",
                name: "fake-cred-two",
                secret: "secret-two",
                projectID: "proj-two",
                roles: ["admin"],
                method: .applicationCredential,
                userID: "user-two",
                userName: "two-admin",
                domain: "default"
            )
        ]

        // Seed a few servers in proj-one
        for i in 1...3 {
            serverIDCounter += 1
            servers.append(FakeServer(
                id: String(format: "srv-%04d", serverIDCounter),
                name: "server-\(i)",
                status: "ACTIVE",
                projectID: "proj-one"
            ))
        }

        // One server in proj-two
        serverIDCounter += 1
        servers.append(FakeServer(
            id: String(format: "srv-%04d", serverIDCounter),
            name: "server-two-1",
            status: "ACTIVE",
            projectID: "proj-two"
        ))
    }

    // MARK: - Token minting

    public func mintToken(credID: String, secret: String, domain: String?, password: String?, userID: String?) -> FakeToken? {
        // Find the credential
        guard let cred = credentials.first(where: { entry in
            if entry.method == .applicationCredential {
                return entry.id == credID && entry.secret == secret
            } else {
                return entry.id == (userID ?? credID) && entry.secret == (password ?? secret)
            }
        }) else {
            return nil
        }

        tokenIDCounter += 1
        let tokenID = String(format: "fake-tok-%04d", tokenIDCounter)
        let token = FakeToken(
            id: tokenID,
            projectID: cred.projectID,
            projectName: cred.projectID.hasSuffix("-one") ? "Project One" : "Project Two",
            domainID: "default",
            domainName: "Default",
            userID: cred.userID,
            userName: cred.userName,
            userDomain: cred.domain,
            roles: cred.roles,
            expiresAt: Date().addingTimeInterval(3600)
        )
        tokens[tokenID] = token
        return token
    }

    public func validateToken(_ tokenID: String) -> FakeToken? {
        guard let token = tokens[tokenID] else { return nil }
        if token.expiresAt < Date() {
            tokens.removeValue(forKey: tokenID)
            return nil
        }
        return token
    }

    // MARK: - Server CRUD

    public func listServers(projectID: String, name: String? = nil, status: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeServer] {
        var result = servers.filter { $0.projectID == projectID }
        if let name {
            result = result.filter { $0.name.contains(name) }
        }
        if let status {
            result = result.filter { $0.status == status }
        }
        if let marker {
            if let idx = result.firstIndex(where: { $0.id == marker }) {
                result = Array(result[(idx + 1)...])
            }
        }
        if let limit, limit < result.count {
            result = Array(result[0..<limit])
        }
        return result
    }

    public func getServer(id: String, projectID: String) -> FakeServer? {
        servers.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createServer(name: String, projectID: String, flavorID: String, region: String = "RegionOne") -> FakeServer {
        serverIDCounter += 1
        let id = String(format: "srv-%04d", serverIDCounter)
        let flavor = flavors.first { $0.id == flavorID }
        let server = FakeServer(
            id: id,
            name: name,
            status: "BUILD",
            flavorID: flavorID,
            flavorName: flavor?.name ?? "unknown",
            projectID: projectID,
            region: region
        )
        servers.append(server)
        return server
    }

    public func deleteServer(id: String, projectID: String) -> Bool {
        let idx = servers.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        servers.remove(at: idx)
        return true
    }

    public func serverAction(id: String, projectID: String, action: String) -> (success: Bool, error: String?) {
        guard let idx = servers.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else {
            return (false, "server not found")
        }
        switch action {
        case "start": servers[idx].status = "ACTIVE"
        case "stop": servers[idx].status = "SHUTOFF"
        case "reboot": servers[idx].status = "REBOOT"
        case "pause": servers[idx].status = "PAUSED"
        case "unpause": servers[idx].status = "ACTIVE"
        case "suspend": servers[idx].status = "SUSPENDED"
        case "resume": servers[idx].status = "ACTIVE"
        case "lock": servers[idx].status = "LOCKED"
        case "unlock": servers[idx].status = "ACTIVE"
        case "shelve": servers[idx].status = "SHELVED"
        case "unshelve": servers[idx].status = "ACTIVE"
        case "rescue": servers[idx].status = "RESCUE"
        case "unrescue": servers[idx].status = "ACTIVE"
        default:
            return (false, "unknown action: \(action)")
        }
        servers[idx].updated = Date()
        return (true, nil)
    }
}
