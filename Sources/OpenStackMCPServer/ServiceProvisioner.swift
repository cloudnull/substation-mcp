import Foundation
import HTTPTypes
import Logging
import NIOCore
import OpenStackClient

// MARK: - Service user + application credential provisioning (spec §11.3)
//
/// Idempotently creates the substation-mcp **service user** (in the OpenStack
/// `service` domain, mirroring `nova_service_user`) and its **application
/// credential**, then returns the credentials so the caller can write them to a
/// k8s Secret. This is the deployment-solution identity: a standing, reusable
/// credential (not a one-shot token) that the server uses for catalog
/// registration and the login page.
///
/// The core is pure against a `Transport`; the CLI shim resolves the cloud,
/// builds the transport, and mints the admin token from the operator-supplied
/// credential.
public struct ServiceProvisioner {
    /// Outcome of provisioning. `userID`/`appCredID` identify what was created
    /// or reused; `appCredSecret` is non-nil ONLY when this run created the app
    /// credential (a reused credential's secret is not recoverable, so the
    /// caller must already have it).
    public struct Result: Sendable {
        public let userID: String
        public let domainName: String
        public let username: String
        public let appCredID: String
        public let appCredName: String
        /// The plaintext app-credential secret — present only on creation.
        public let appCredSecret: String?
        /// True when the user was already present (reused, not created).
        public let userReused: Bool
        /// True when the app credential was already present (reused).
        public let appCredReused: Bool
    }

    public let username: String
    public let domainName: String
    public let appCredName: String
    public let roles: [String]
    /// Admin token used for the identity write calls (X-Auth-Token).
    private let adminToken: String
    private let transport: Transport
    private let logger: Logger
    /// Mints a token as the given (password-authenticated) user. Used to create
    /// the application credential under the service user's ownership.
    ///
    /// Defaults to the in-process `LoginMinter` password mint. Some Keystones
    /// (e.g. the Genestack/RDO in-cluster one) reject the in-process
    /// AsyncHTTPClient password-mint POST with a spurious 400 even though the
    /// body is byte-identical to a curl request that succeeds — so the
    /// `provision` command can inject a `curl`-based minter (the runtime image
    /// ships curl) to work around that. The signature is
    /// (userID, domain, password) -> tokenID.
    private let passwordTokenMinter: (String, String?, String) async throws -> String

    public init(
        username: String,
        domainName: String = "service",
        appCredName: String = "substation-cred",
        roles: [String] = ["admin"],
        adminToken: String,
        transport: Transport,
        logger: Logger = Logger(label: "service-provisioner"),
        passwordTokenMinter: ((String, String?, String) async throws -> String)? = nil
    ) {
        self.username = username
        self.domainName = domainName
        self.appCredName = appCredName
        self.roles = roles
        self.adminToken = adminToken
        self.transport = transport
        self.logger = logger
        if let minter = passwordTokenMinter {
            self.passwordTokenMinter = minter
        } else {
            let m = LoginMinter(transport: transport, logger: logger)
            self.passwordTokenMinter = { id, domain, password in
                try await m.mint(method: .password(userID: id, domain: domain, password: password, projectName: nil)).id
            }
        }
    }

    /// Ensure the service user + app credential exist (idempotent).
    public func ensureServiceIdentity() async throws -> Result {
        let (userID, userReused, userPassword) = try await ensureUser()
        let (appCredID, appCredSecret, appCredReused) = try await ensureAppCredential(userID: userID, userPassword: userPassword)
        return Result(
            userID: userID,
            domainName: domainName,
            username: username,
            appCredID: appCredID,
            appCredName: appCredName,
            appCredSecret: appCredSecret,
            userReused: userReused,
            appCredReused: appCredReused
        )
    }

    // MARK: - user

    /// Find (by name + domain) or create the service user (with a generated
    /// password), and ensure the required roles are assigned on the domain.
    /// Returns (id, reused, password?). The password is only known when this
    /// run created the user; it is needed to mint a token as the user so the
    /// application credential it creates is owned by the user (not the admin).
    private func ensureUser() async throws -> (id: String, reused: Bool, password: String?) {
        // 1. Look up the domain id.
        let domainID = try await fetchDomainID(name: domainName)

        // 2. Look up the user by name + domain.
        let userResp = try await identityRequest(
            method: "GET",
            path: "/v3/users",
            query: [
                URLQueryItem(name: "name", value: username),
                URLQueryItem(name: "domain_id", value: domainID),
            ]
        )
        struct User: Decodable { let id: String; let name: String?; let domain_id: String? }
        struct UserList: Decodable { let users: [User] }
        let (userStatus, userBody) = userResp
        if userStatus == 200,
           let list = try? JSONDecoder().decode(UserList.self, from: userBody),
           let existing = list.users.first(where: { $0.name == username }) {
            logger.info("Service user already exists", metadata: ["id": .string(existing.id)])
            try await ensureRoleAssignments(userID: existing.id, domainID: domainID)
            return (existing.id, true, nil)
        }

        // 3. Create the user (domain-scoped) with a generated password. The
        // password is required so we can mint a token *as the user* to create
        // its own application credential (a Keystone app-cred is owned by the
        // token's user, not by an admin who passes a user_id).
        let password = Self.generateSecret()
        let createBody = """
        {"user":{"name":"\(username)","domain_id":"\(domainID)","password":"\(password)","enabled":true}}
        """
        let (cStatus, cBody) = try await identityRequest(method: "POST", path: "/v3/users", body: createBody)
        guard cStatus == 201 else {
            throw ServiceProvisionerError.identityHTTP(cStatus, cBody)
        }
        struct UserResp: Decodable { let user: User }
        guard let resp = try? JSONDecoder().decode(UserResp.self, from: cBody) else {
            throw ServiceProvisionerError.decode
        }
        logger.info("Created service user", metadata: ["id": .string(resp.user.id), "domain": .string(domainName)])
        try await ensureRoleAssignments(userID: resp.user.id, domainID: domainID)
        return (resp.user.id, false, password)
    }

    /// Generate a 32-byte hex secret using a portable CSPRNG.
    static func generateSecret() -> String {
        var gen = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &gen) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Ensure each required role is assigned to the user on the domain.
    ///
    /// Uses the domain-scoped role-assignment endpoints from the v3 Identity
    /// API (docs.openstack.org/api-ref/identity/v3):
    ///   - check: GET  /v3/domains/{domain_id}/users/{user_id}/roles
    ///   - grant: PUT  /v3/domains/{domain_id}/users/{user_id}/roles/{role_id}
    /// The old `POST /v3/role_assignments` (collection) is a 405 on most
    /// clouds; the scoped PUT is the documented grant.
    private func ensureRoleAssignments(userID: String, domainID: String) async throws {
        struct Role: Decodable { let id: String; let name: String? }
        for role in roles {
            // Look up the role id.
            let (status, body) = try await identityRequest(method: "GET", path: "/v3/roles", query: [URLQueryItem(name: "name", value: role)])
            guard status == 200 else {
                throw ServiceProvisionerError.identityHTTP(status, body)
            }
            struct RoleList: Decodable { let roles: [Role] }
            guard let list = try? JSONDecoder().decode(RoleList.self, from: body),
                  let roleID = list.roles.first(where: { $0.name == role })?.id else {
                throw ServiceProvisionerError.roleNotFound(role)
            }

            // Check if already assigned (GET the user's roles on the domain).
            let (gStatus, gBody) = try await identityRequest(
                method: "GET",
                path: "/v3/domains/\(domainID)/users/\(userID)/roles"
            )
            if gStatus == 200 {
                struct RoleRef: Decodable { let id: String; let name: String? }
                struct RoleList2: Decodable { let roles: [RoleRef] }
                if let rl = try? JSONDecoder().decode(RoleList2.self, from: gBody),
                   rl.roles.contains(where: { $0.id == roleID }) {
                    logger.debug("Role already assigned", metadata: ["role": .string(role)])
                    continue
                }
            }

            // Grant (PUT, empty body, 204 No Content on success).
            let (aStatus, aBody) = try await identityRequest(
                method: "PUT",
                path: "/v3/domains/\(domainID)/users/\(userID)/roles/\(roleID)"
            )
            guard aStatus == 201 || aStatus == 204 else {
                throw ServiceProvisionerError.identityHTTP(aStatus, aBody)
            }
            logger.info("Assigned role to service user", metadata: ["role": .string(role), "user": .string(userID)])
        }
    }

    // MARK: - application credential

    /// Find (by name) or create the application credential for the user.
    /// Returns (id, secret, reused). The secret is non-nil only on creation.
    ///
    /// Application credentials are per-user resources in the v3 Identity API
    /// (docs.openstack.org/api-ref/identity/v3):
    ///   - list:   GET  /v3/users/{user_id}/application_credentials
    ///   - create: POST /v3/users/{user_id}/application_credentials
    /// A Keystone application credential is owned by the *token's* user, so to
    /// create one for the service user we authenticate **as** that user. On
    /// creation we mint a token via the user's password, then POST the app-cred
    /// under that token. On reuse (user already existed, password unknown) we
    /// fall back to the admin token — the list-by-name check above still finds
    /// an existing cred, and create-under-admin is best-effort.
    private func ensureAppCredential(userID: String, userPassword: String?) async throws -> (id: String, secret: String?, reused: Bool) {
        // Look up existing app credentials for the user.
        let (status, body) = try await identityRequest(method: "GET", path: "/v3/users/\(userID)/application_credentials")
        struct Cred: Decodable { let id: String; let name: String? }
        struct CredList: Decodable { let application_credentials: [Cred] }
        if status == 200,
           let list = try? JSONDecoder().decode(CredList.self, from: body),
           let existing = list.application_credentials.first(where: { $0.name == appCredName }) {
            logger.info("Application credential already exists", metadata: ["id": .string(existing.id)])
            return (existing.id, nil, true)
        }

        let secret = Self.generateSecret()
        let createBody = """
        {"application_credential":{"name":"\(appCredName)","secret":"\(secret)","unrestricted":true,"description":"substation-mcp service identity (auto-provisioned)","expires_at":null}}
        """

        // Mint a token as the service user so the app-cred it creates is owned
        // by the user. Falls back to the admin token if the password is unknown
        // (user was reused) — acceptable on clouds that honor an explicit owner.
        let token: String
        if let pw = userPassword {
            token = try await passwordTokenMinter(username, domainName, pw)
        } else {
            logger.warning("Service user reused without a known password; creating app-cred under the admin token", metadata: ["user": .string(userID)])
            token = adminToken
        }

        let (cStatus, cBody) = try await identityRequest(method: "POST", path: "/v3/users/\(userID)/application_credentials", body: createBody, as: token)
        guard cStatus == 201 else {
            throw ServiceProvisionerError.identityHTTP(cStatus, cBody)
        }
        struct CredResp: Decodable { let application_credential: Cred }
        guard let resp2 = try? JSONDecoder().decode(CredResp.self, from: cBody) else {
            throw ServiceProvisionerError.decode
        }
        logger.info("Created application credential", metadata: ["id": .string(resp2.application_credential.id), "user": .string(userID)])
        return (resp2.application_credential.id, secret, false)
    }

    // MARK: - helpers

    private func fetchDomainID(name: String) async throws -> String {
        // Query without a name filter and match client-side: Keystone domain
        // names are case-sensitive in the API but the convention varies (the
        // default domain's *name* is "Default" while its *id* is "default", and
        // clouds like sat0 expose only that one). Filtering server-side by
        // `?name=<id>` returns empty when the id and name differ in case, which
        // is what made the provisioner report "domain 'default' not found" on
        // sat0. Match on id OR case-insensitive name.
        let (status, body) = try await identityRequest(method: "GET", path: "/v3/domains")
        struct Domain: Decodable { let id: String; let name: String? }
        struct DomainList: Decodable { let domains: [Domain] }
        guard status == 200,
              let list = try? JSONDecoder().decode(DomainList.self, from: body),
              let domain = list.domains.first(where: { $0.id == name || $0.name?.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ServiceProvisionerError.domainNotFound(name)
        }
        return domain.id
    }

    /// Run an identity request, returning (status, body). Throws a transport
    /// error on failure. Sends `as` (default: the admin token) as X-Auth-Token.
    private func identityRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: String? = nil,
        as token: String? = nil
    ) async throws -> (Int, Data) {
        do {
            let (status, bodyData, _) = try await transport.request(
                method: method,
                service: "identity",
                path: path,
                query: query,
                body: body.map { Data($0.utf8) },
                tokenOverride: token ?? adminToken
            )
            return (status, bodyData)
        } catch {
            throw ServiceProvisionerError.transport(error)
        }
    }
}

public enum ServiceProvisionerError: Error, CustomStringConvertible {
    case identityHTTP(Int, Data?)
    case decode
    case domainNotFound(String)
    case roleNotFound(String)
    case transport(Error)

    public var description: String {
        switch self {
        case .identityHTTP(let s, let b):
            let snippet = b.flatMap { String(decoding: $0.prefix(300), as: UTF8.self) } ?? ""
            return "identity API returned HTTP \(s): \(snippet)"
        case .decode: return "failed to decode identity API response"
        case .domainNotFound(let n): return "domain '\(n)' not found"
        case .roleNotFound(let n): return "role '\(n)' not found"
        case .transport(let e): return "transport error: \(e)"
        }
    }
}
