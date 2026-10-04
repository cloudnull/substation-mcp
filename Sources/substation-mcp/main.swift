import ArgumentParser
import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdMCP
import Logging
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix
import OpenStackClient
import OpenStackMCPServer

// MARK: - Top-level CLI (spec §11.3)

/// OpenStack MCP server.
struct OpenStackMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "substation-mcp",
        abstract: "Expose an OpenStack cloud as an MCP server.",
        subcommands: [
            ServeCommand.self,
            StdioCommand.self,
            HealthzCommand.self,
            CheckCommand.self,
            AccessRulesCommand.self,
            ToolsCommand.self,
            RegisterCatalogCommand.self,
            ProvisionCommand.self,
            WaitSecretCommand.self,
            WriteSecretCommand.self,
            MarkSecretCommand.self,
            ReadSecretCommand.self,
            ConformanceCommand.self,
        ],
        defaultSubcommand: nil
    )
}

// MARK: - serve (spec §11.3, §7.1)

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the HTTP (Streamable-HTTP) MCP server."
    )

    @Option(name: .long, help: "Config file (YAML).") var config: String?
    @Option(name: .long, help: "Cloud name (from clouds.yaml).") var cloud: String?
    @Option(name: .long, help: "Host to bind.") var host: String?
    @Option(name: .long, help: "Port to bind.") var port: Int?
    @Option(name: .long, help: "Public base URL (for PRM + challenges).") var publicURL: String?
    @Option(name: .long, help: "Read-only mode.") var readOnly: Bool = false
    @Option(name: .long, help: "Log level.") var logLevel: String = "info"

    func run() async throws {
        let cfg = ConfigLoader.load(args: [
            "config": config, "host": host, "port": port.map { "\($0)" },
            "publicURL": publicURL, "readOnly": readOnly ? "true" : "false",
            "logLevel": logLevel,
        ])
        // Bootstrap metrics before any are emitted (spec §12); must run once,
        // before the first request, so the Prometheus collector sees every
        // registration.
        _ = bootstrapMetrics()
        let logger = makeLogger(level: cfg.logLevel, format: cfg.logFormat, sink: .standardOutput)
        let cloudEntry = try resolveCloud(cfg: cfg, name: cloud, logger: logger)

        let tokenStore = TokenStore(logger: logger)
        let app = ServeApp(config: cfg, cloud: cloudEntry, tokenStore: tokenStore, logger: logger)

        logger.info("substation-mcp serving", metadata: [
            "cloud": "\(cloudEntry.name)",
            "host": "\(cfg.serverHost)",
            "port": "\(cfg.serverPort)",
            "endpoint": "\(cfg.serverEndpoint)",
        ])
        try await app.app.run()
    }
}

// MARK: - stdio (spec §11.3, §7.3 stdio)

struct StdioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stdio",
        abstract: "Run the MCP server over stdio (single cloud, single token)."
    )

    @Option(name: .long, help: "Config file (YAML).") var config: String?
    @Option(name: .long, help: "Cloud name (from clouds.yaml).") var cloud: String?
    @Option(name: .long, help: "Bearing token id (X-Auth-Token) to use for the session.") var token: String?
    @Option(name: .long, help: "Log level.") var logLevel: String = "info"

    func run() async throws {
        let cfg = ConfigLoader.load(args: ["config": config, "logLevel": logLevel])
        _ = bootstrapMetrics()
        // stdio: log to stderr so JSON never pollutes the MCP JSON-RPC framing.
        let logger = makeLogger(level: cfg.logLevel, format: "logfmt", sink: .standardError)
        let cloudEntry = try resolveCloud(cfg: cfg, name: cloud, logger: logger)

        // stdio: single token for the lifetime of the process.
        guard let tokenID = token ?? ProcessInfo.processInfo.environment["OSMCP_STDIO_TOKEN"] else {
            throw CLIError(message: "stdio mode requires --token (or OSMCP_STDIO_TOKEN)")
        }
        let wiring = CloudWiring(config: cfg, cloud: cloudEntry, logger: logger)
        let policy = Policy(
            readOnly: cfg.policyReadOnly,
            denyResources: Set(cfg.policyDenyResources),
            maxListLimit: cfg.policyMaxListLimit,
            maxCallsPerMinute: cfg.policyMaxCallsPerMinute
        )
        let vt = try await wiring.validator.validate(tokenID)
        let identity = ValidatedIdentity(
            tokenID: vt.token.id,
            projectID: vt.token.project.id,
            scopes: vt.scopes.map { $0.rawValue },
            raw: HummingbirdMCP.AnyTokenPayload(data: try JSONEncoder().encode(vt.token))
        )
        let factory = wiring.makeServerFactory(
            policy: policy,
            scopeMode: cfg.authScopesPerService ? .perService : .coarse,
            logger: logger
        )
        let server = await factory(identity)

        let transport = StdioTransport(logger: nil)
        logger.info("substation-mcp running over stdio", metadata: [
            "cloud": "\(cloudEntry.name)",
            "project": "\(vt.token.project.id)",
        ])
        try await server.start(transport: transport)
        // Block until the transport's read loop finishes (EOF on stdin).
        await transport.disconnect()
        await server.stop()
    }
}

// MARK: - healthz (spec §11.3)

struct HealthzCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "healthz", abstract: "Print liveness JSON and exit 0.")

    func run() throws {
        print(#"{"alive":true}"#)
    }
}

struct CLIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - check (spec §11.3)

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "check", abstract: "Validate a token and print identity, scopes, regions, versions, and access-rule gaps.")

    @Option(name: .long, help: "Config file (YAML).") var config: String?
    @Option(name: .long, help: "Cloud name (from clouds.yaml).") var cloud: String?
    @Option(name: .long, help: "Token id (X-Auth-Token) to check. Defaults to OS_AUTH_TOKEN.") var token: String?
    @Option(name: .long, help: "Log level.") var logLevel: String = "info"

    func run() async throws {
        let cfg = ConfigLoader.load(args: ["config": config, "logLevel": logLevel])
        let logger = makeLogger(level: cfg.logLevel, format: "logfmt", sink: .standardError)
        let cloudEntry = try resolveCloud(cfg: cfg, name: cloud, logger: logger)

        let wiring = CloudWiring(config: cfg, cloud: cloudEntry, logger: logger)
        defer { wiring.shutdown() }

        // Token: explicit --token > OS_AUTH_TOKEN > mint from the cloud's app-cred (discarded after).
        let tokenID: String
        if let t = token ?? ProcessInfo.processInfo.environment["OS_AUTH_TOKEN"] {
            tokenID = t
        } else if let credID = cloudEntry.appCredID, let secret = cloudEntry.appCredSecret {
            let minter = LoginMinter(transport: wiring.transport, logger: logger)
            let minted = try await minter.mint(method: .applicationCredential(id: credID, secret: Array(secret.utf8).map { Int8($0) }))
            tokenID = minted.id
        } else {
            throw CLIError(message: "check: no token (--token/OS_AUTH_TOKEN) and no app-cred in the cloud to mint one")
        }

        do {
            let vt = try await wiring.validator.validate(tokenID)
            let whoami = await wiring.client.whoami(vt)
            let region = await wiring.client.defaultRegion(vt)

            // Negotiated versions per service present in the catalog. The version
            // doc is fetched from the service's resolved endpoint (catalog host on
            // multi-endpoint clouds, authURL on single-endpoint), not the authURL
            // root — so we resolve the endpoint base per service first.
            var versions: [String: Microversion] = [:]
            for svc in ["compute", "volumev3"] {
                guard whoami.services[svc] != nil,
                      let profile = ServiceVersionProfile.profile(for: svc) else { continue }
                let basePath = svc == "compute" ? "nova" : "cinder/v3"
                let ep = resolveServiceEndpoint(
                    vt: vt, region: region, cloud: wiring.cloud,
                    basePath: basePath, serviceRoot: svc == "compute" ? "" : "v3",
                    serviceType: svc, fullPath: "\(basePath)/__version__"
                )
                let negotiator = VersionNegotiator(
                    transport: wiring.transport, cache: wiring.cache,
                    profile: profile, endpointBase: { ep.overrideBase },
                    tokenOverride: vt.token.id, logger: logger
                )
                do { versions[svc] = try await negotiator.negotiate(region: region, versionDocPath: ep.pathPrefix).version }
                catch { /* service absent or unreachable — skip */ }
            }

            // Neutron extensions.
            var extAliases: [String] = []
            if whoami.services["network"] != nil {
                do {
                    let networkRegion = await wiring.client.network(region: region)
                    let ext = try await networkRegion.discoverExtensions(vt, region: region)
                    extAliases = Array(ext.aliases)
                } catch { /* network absent — skip */ }
            }

            // Access rules: whoami carries them when the credential is
            // rule-bound. `unrestricted` is present for a plain (unrestricted)
            // token; when absent, rules are the comparison source.
            let rules = whoami.accessRules
            let unrestricted = whoami.unrestricted

            let report = CheckReport.build(
                whoami: whoami,
                versions: versions,
                neutronExtensions: extAliases,
                accessRules: rules,
                unrestricted: unrestricted
            )
            let (stdout, notes) = report.render()
            print(stdout)
            if !notes.isEmpty {
                FileHandle.standardError.write(Data((notes + "\n").utf8))
            }
        } catch {
            // Auth failure → exit 1 (ArgumentParser throws with a specific code).
            throw CLIExit(code: 1, message: "check: token validation failed: \(error)")
        }
    }
}

/// A throwable carrying an explicit process exit code.
struct CLIExit: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { message }
}

// MARK: - access-rules (spec §11.3)

struct AccessRulesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "access-rules", abstract: "Emit the Keystone access-rule JSON for a mode/service/resource subset.")

    @Option(name: .long, help: "Mode: read-only (GET only) or operator (all methods).") var mode: String = "operator"
    @Option(name: .long, help: "Comma-separated services to include (e.g. compute,network).") var services: String?
    @Option(name: .long, help: "Comma-separated resources to EXCLUDE (e.g. flavor,subnet).") var resources: String?
    @Option(name: .long, help: "Neutron extensions present (e.g. address-group).") var extensions: String?

    func run() async throws {
        let readOnly = mode == "read-only"
        let svc = services.map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }).subtracting([""]) }
        let res = resources.map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }).subtracting([""]) }
        let exts = extensions.map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) } ?? []

        do {
            let json = try AccessRulesGenerator.json(
                readOnly: readOnly,
                services: svc,
                resources: res,
                neutronExtensions: exts
            )
            print(json)
        } catch {
            throw CLIError(message: "access-rules: \(error)")
        }
        // The spec's enforcement caveat always goes to stderr.
        let note = "note: for these rules to be enforced, each service must be registered with the correct service_type in keystonemiddleware."
        FileHandle.standardError.write(Data((note + "\n").utf8))
    }
}

// MARK: - tools (spec §11.3)

struct ToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tools", abstract: "Dump the tool list (name, description, annotations, inputSchema) for the effective policy.")

    @Flag(name: .long, help: "Machine-readable JSON output.") var json: Bool = false
    @Flag(name: .long, help: "Read-only policy (9 verb + 3 task tools) instead of the full set (15 verb + 3 task).") var readOnly: Bool = false

    func run() async throws {
        let catalog = ResourceCatalog.phase1()
        let tools = ToolListFormatter.tools(readOnly: readOnly, catalog: catalog)
        do {
            if json {
                print(try ToolListFormatter.json(tools))
            } else {
                print(ToolListFormatter.table(tools))
            }
        } catch {
            throw CLIError(message: "tools: \(error)")
        }
    }
}

// MARK: - register-catalog (spec §6.5)

struct RegisterCatalogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "register-catalog", abstract: "Install the MCP service + public/internal/admin endpoints in the Keystone catalog (idempotent).")

    @Option(name: .long, help: "Config file (YAML).") var config: String?
    @Option(name: .long, help: "Cloud name (from clouds.yaml).") var cloud: String?
    @Option(name: .long, help: "Region to register endpoints in.") var region: String
    @Option(name: .long, help: "Public URL of the MCP endpoint.") var publicURL: String
    @Option(name: .long, help: "Internal URL (defaults to --public-url).") var internalURL: String?
    @Option(name: .long, help: "Admin URL (defaults to --public-url).") var adminURL: String?
    @Option(name: .long, help: "Identity-admin token (X-Auth-Token). Defaults to OS_AUTH_TOKEN. If unset, mints one from the cloud's application credential (a service-domain user) and discards it after.") var adminToken: String?
    @Option(name: .long, help: "Username (password auth to mint the admin token from).") var adminUser: String?
    @Option(name: .long, help: "Domain of the admin user (password auth).") var adminUserDomain: String?
    @Option(name: .long, help: "Password of the admin user (password auth).") var adminPassword: String?
    @Option(name: .long, help: "Project to scope the admin token to (password auth) — the cloud's admin project for cross-domain privileges.") var adminProject: String?
    @Option(name: .long, help: "Identity endpoint override for catalog registration (e.g. the in-cluster Keystone URL, for the identity ops). Defaults to the cloud's auth_url.") var authURL: String?
    @Option(name: .long, help: "Endpoint for the curl admin-token mint (e.g. the public Keystone URL, which accepts scoped mints the in-cluster svc rejects). Defaults to --auth-url / the cloud's auth_url.") var mintURL: String?
    @Option(name: .long, help: "Log level.") var logLevel: String = "info"

    func run() async throws {
        let cfg = ConfigLoader.load(args: ["config": config, "logLevel": logLevel])
        let logger = makeLogger(level: cfg.logLevel, format: "logfmt", sink: .standardError)
        var cloudEntry = try resolveCloud(cfg: cfg, name: cloud, logger: logger)

        if let override = authURL, let u = URL(string: override) {
            cloudEntry = CloudEntry(
                name: cloudEntry.name,
                authURL: u,
                regionName: cloudEntry.regionName,
                interface: cloudEntry.interface,
                cacert: cloudEntry.cacert,
                verify: cloudEntry.verify,
                appCredID: cloudEntry.appCredID,
                appCredSecret: cloudEntry.appCredSecret
            )
        }

        let wiring = CloudWiring(config: cfg, cloud: cloudEntry, logger: logger)
        defer { wiring.shutdown() }

        // Admin token: explicit --admin-token > OS_AUTH_TOKEN > mint from the
        // cloud's application credential (a service-domain user, e.g.
        // `substation` in the `service` domain, mirroring `nova_service_user`).
        // The minted token is discarded once registration completes. Catalog
        // writes need the admin role; the service user is created with it.
        let admin: String
        let mintEndpoint = (mintURL?.isEmpty == false ? mintURL : nil) ?? cloudEntry.authURL?.absoluteString ?? ""
        if let t = adminToken ?? ProcessInfo.processInfo.environment["OS_AUTH_TOKEN"] {
            admin = t
        } else if let credID = cloudEntry.appCredID, let secret = cloudEntry.appCredSecret {
            let minter = LoginMinter(transport: wiring.transport, logger: logger)
            let minted = try await minter.mint(method: .applicationCredential(id: credID, secret: Array(secret.utf8).map { Int8($0) }))
            admin = minted.id
        } else if let u = adminUser ?? ProcessInfo.processInfo.environment["OS_USERNAME"],
                  let p = adminPassword ?? ProcessInfo.processInfo.environment["OS_PASSWORD"] {
            let d = adminUserDomain ?? ProcessInfo.processInfo.environment["OS_USER_DOMAIN_NAME"] ?? "default"
            let minter = ProvisionCommand.curlPasswordMinter(authURL: mintEndpoint, project: adminProject, logger: logger)
            admin = try await minter(u, d, p)
        } else {
            throw CLIError(message: "register-catalog: no admin token (--admin-token/OS_AUTH_TOKEN), no app-cred, and no password (--admin-user/--admin-password) supplied")
        }

        do {
            let registrar = CatalogRegistrar(
                transport: wiring.transport,
                region: region,
                publicURL: publicURL,
                internalURL: internalURL,
                adminURL: adminURL,
                adminToken: admin,
                logger: logger,
                identityClient: ProvisionCommand.curlIdentityClient(
                    baseURL: cloudEntry.authURL?.absoluteString ?? "",
                    logger: logger
                )
            )
            let result = try await registrar.ensureCatalog()
            print("service: \(result.serviceID)")
            for (i, ep) in result.endpointIDs.enumerated() {
                let marker = result.reusedEndpointIDs.contains(ep) ? "reused" : "created"
                print("\(CatalogRegistrar.interfaces[i]): \(ep) (\(marker))")
            }
        } catch {
            throw CLIExit(code: 1, message: "register-catalog: \(error)")
        }
    }
}

// MARK: - provision (service user + application credential)
//
// Idempotently creates the substation-mcp service user in the OpenStack
// `service` domain (mirroring `nova_service_user`) and its application
// credential, then prints a JSON result. Used by the Helm chart's provisioner
// Job (post-install hook) to create the deployment's standing identity from
// operator-supplied admin credentials. The admin token is resolved as:
//   --admin-token > OS_AUTH_TOKEN > --app-cred-id/--app-cred-secret >
//   --username/--password (OS_USERNAME/OS_PASSWORD).
struct ProvisionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provision",
        abstract: "Idempotently create the service user + application credential (prints JSON)."
    )

    @Option(name: .long, help: "Config file (YAML).") var config: String?
    @Option(name: .long, help: "Cloud name (from clouds.yaml).") var cloud: String?
    @Option(name: .long, help: "Username to create/reuse in the service domain.") var username: String = "substation"
    @Option(name: .long, help: "Domain to create the user in.") var domain: String = "service"
    @Option(name: .long, help: "Name of the application credential.") var appCredName: String = "substation-cred"
    @Option(name: .long, help: "Comma-separated roles to grant (default: admin).") var roles: String = "admin"

    // Admin token (resolved, see above):
    @Option(name: .long, help: "Identity-admin token (X-Auth-Token).") var adminToken: String?
    @Option(name: .long, help: "App-cred id to mint the admin token from.") var appCredID: String?
    @Option(name: .long, help: "App-cred secret to mint the admin token from.") var appCredSecret: String?
    @Option(name: .long, help: "Username (password auth to mint the admin token from).") var adminUser: String?
    @Option(name: .long, help: "Domain of the admin user (password auth).") var adminUserDomain: String?
    @Option(name: .long, help: "Password of the admin user (password auth).") var adminPassword: String?
    /// Project to scope the admin token to (password auth). A project-scoped
    /// token to the cloud's admin project is the full-privilege credential
    /// needed to see/manage all domains. When unset, the admin token is
    /// domain-scoped (sees only its own domain).
    @Option(name: .long, help: "Project to scope the admin token to (password auth). Use the cloud's admin project for full cross-domain privileges.") var adminProject: String?

    /// Optional override for the identity endpoint the provisioner's TRANSPORT
    /// (identity ops: create user, role grant, app-cred, catalog) uses. When
    /// set, the provisioner builds its transport against this URL instead of
    /// the cloud's auth_url. Defaults to the cloud's auth_url (the in-cluster
    /// keystone svc), which accepts identity ops with a valid token.
    @Option(name: .long, help: "Identity endpoint override for the provisioner's identity ops (the transport). Defaults to the cloud's auth_url.") var authURL: String?

    /// Endpoint the curl token mints target. Separate from --auth-url because
    /// on Genestack/RDO the in-cluster keystone svc REJECTS scoped password mints
    /// (spurious 400 "invalid JSON") while the PUBLIC endpoint accepts them and
    /// is pod-reachable. Tokens minted on public are valid on the in-cluster svc
    /// (same Keystone backend), so mints go to public and identity ops go to
    /// in-cluster. Defaults to --auth-url when unset.
    @Option(name: .long, help: "Endpoint for the curl token mints (e.g. the public Keystone URL). Defaults to --auth-url / the cloud's auth_url.") var mintURL: String?

    @Option(name: .long, help: "Log level.") var logLevel: String = "info"

    func run() async throws {
        let cfg = ConfigLoader.load(args: ["config": config, "logLevel": logLevel])
        let logger = makeLogger(level: cfg.logLevel, format: "logfmt", sink: .standardError)
        var cloudEntry = try resolveCloud(cfg: cfg, name: cloud, logger: logger)

        // Optional identity-endpoint override for provisioning. When set, the
        // provisioner's transport + curl mints target this URL instead of the
        // cloud's auth_url. (The running server keeps the cloud's auth_url.)
        if let override = authURL {
            guard let u = URL(string: override) else {
                throw CLIError(message: "provision: invalid --auth-url '\(override)'")
            }
            cloudEntry = CloudEntry(
                name: cloudEntry.name,
                authURL: u,
                regionName: cloudEntry.regionName,
                interface: cloudEntry.interface,
                cacert: cloudEntry.cacert,
                verify: cloudEntry.verify,
                appCredID: cloudEntry.appCredID,
                appCredSecret: cloudEntry.appCredSecret
            )
            logger.info("provision: using identity endpoint override", metadata: ["url": .string(override)])
        }

        let wiring = CloudWiring(config: cfg, cloud: cloudEntry, logger: logger)
        defer { wiring.shutdown() }

        // Resolve the admin token: explicit > OS_AUTH_TOKEN > app-cred mint > password mint.
        //
        // Password mints use curl (not the in-process LoginMinter) because some
        // Keystones (e.g. the Genestack/RDO in-cluster one) reject the
        // AsyncHTTPClient password-mint POST with a spurious 400 even though the
        // body is byte-identical to a curl request that succeeds. curl ships in
        // the runtime image and is proven to work against that Keystone. App-cred
        // mints use the in-process minter (that path works).
        // The curl mints target --mint-url when given (and non-empty — the
        // public endpoint, which accepts scoped password mints the in-cluster
        // svc rejects), otherwise the transport's auth_url. Tokens minted on
        // public are valid on the in-cluster svc (same Keystone backend).
        let mintEndpoint = (mintURL?.isEmpty == false ? mintURL : nil) ?? cloudEntry.authURL?.absoluteString ?? ""
        // Admin token minter: project-scoped when --admin-project is given (the
        // full-privilege cross-domain credential), else domain-scoped.
        let adminMintViaCurl = Self.curlPasswordMinter(authURL: mintEndpoint, project: adminProject, logger: logger)
        // Service-user token minter: always domain-scoped to the user's domain
        // (used to mint a token AS the service user so the app-cred it creates
        // is owned by that user).
        let userMintViaCurl = Self.curlPasswordMinter(authURL: mintEndpoint, project: nil, logger: logger)

        let admin: String
        if let t = adminToken ?? ProcessInfo.processInfo.environment["OS_AUTH_TOKEN"] {
            admin = t
        } else if let id = appCredID ?? ProcessInfo.processInfo.environment["OS_APPLICATION_CREDENTIAL_ID"],
                  let secret = appCredSecret ?? ProcessInfo.processInfo.environment["OS_APPLICATION_CREDENTIAL_SECRET"] {
            let minter = LoginMinter(transport: wiring.transport, logger: logger)
            let minted = try await minter.mint(method: .applicationCredential(id: id, secret: Array(secret.utf8).map { Int8($0) }))
            admin = minted.id
        } else if let u = adminUser ?? ProcessInfo.processInfo.environment["OS_USERNAME"],
                  let p = adminPassword ?? ProcessInfo.processInfo.environment["OS_PASSWORD"] {
            let d = adminUserDomain ?? ProcessInfo.processInfo.environment["OS_USER_DOMAIN_NAME"] ?? "admin"
            admin = try await adminMintViaCurl(u, d, p)
        } else {
            throw CLIError(message: "provision: no admin token (--admin-token/OS_AUTH_TOKEN), no app-cred (--app-cred-id/--app-cred-secret), and no password (--admin-user/--admin-password) supplied")
        }
        if ProcessInfo.processInfo.environment["PROVISION_DEBUG"] != nil {
            FileHandle.standardError.write("PROVISION_DEBUG admin token len: \(admin.count) head: \(admin.prefix(24))...\n".data(using: .utf8)!)
        }

        do {
            let roleList = roles.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Inject the curl-based identity client + password minter so the
            // provisioner avoids the in-process AsyncHTTPClient's response-parse
            // failures (invalidHeaderFieldValues) against the Apache-fronted
            // in-cluster keystone. Identity ops hit the cloud's auth_url
            // (in-cluster); mints hit --mint-url (public).
            let identityBase = cloudEntry.authURL?.absoluteString ?? ""
            let provisioner = ServiceProvisioner(
                username: username,
                domainName: domain,
                appCredName: appCredName,
                roles: roleList,
                adminToken: admin,
                transport: wiring.transport,
                logger: logger,
                passwordTokenMinter: userMintViaCurl,
                identityClient: Self.curlIdentityClient(baseURL: identityBase, logger: logger)
            )
            let result = try await provisioner.ensureServiceIdentity()

            // Emit machine-readable JSON on stdout (the provisioner Job's sidecar
            // captures it and writes the app-cred to a k8s Secret).
            let secretValue: String = result.appCredSecret ?? ""
            let json = """
            {
              "user_id": "\(result.userID)",
              "username": "\(result.username)",
              "domain": "\(result.domainName)",
              "app_cred_id": "\(result.appCredID)",
              "app_cred_name": "\(result.appCredName)",
              "app_cred_secret": "\(secretValue)",
              "app_cred_secret_created": \(result.appCredSecret != nil),
              "user_reused": \(result.userReused),
              "app_cred_reused": \(result.appCredReused)
            }
            """
            print(json)
        } catch {
            throw CLIExit(code: 1, message: "provision: \(error)")
        }
    }

    /// Build a closure that mints a Keystone token via a `curl` subprocess.
    ///
    /// Used for password mints: some Keystones reject the in-process
    /// AsyncHTTPClient password-mint POST with a spurious 400 even though the
    /// body is byte-identical to a curl request that succeeds (verified against
    /// the Genestack/RDO Keystone). curl ships in the UBI10 runtime image.
    ///
    /// `project` (optional) makes the token project-scoped; otherwise it is
    /// domain-scoped. A project-scoped token to the cloud's `admin` project is
    /// the full-privilege credential needed to see/manage ALL domains and
    /// create users/app-creds/role-grants (a domain-scoped or unscoped token
    /// only sees its own domain). The JSON body is built with JSONSerialization
    /// so it is always well-formed regardless of password contents.
    static func curlPasswordMinter(
        authURL: String,
        project: String? = nil,
        logger: Logger
    ) -> (String, String?, String) async throws -> String {
        return { userID, domain, password in
            let dom = domain ?? "default"
            // Build the JSON body safely (password may contain any chars).
            var user: [String: Any] = ["name": userID, "password": password]
            user["domain"] = ["name": dom]
            var auth: [String: Any] = ["identity": ["methods": ["password"], "password": ["user": user]]]
            if let project {
                auth["scope"] = ["project": ["name": project, "domain": ["name": dom]]]
            } else {
                auth["scope"] = ["domain": ["name": dom]]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: ["auth": auth], options: []),
                  let body = String(data: data, encoding: .utf8) else {
                throw CLIError(message: "provision: could not build mint JSON body")
            }
            let base = authURL.hasSuffix("/") ? String(authURL.dropLast()) : authURL
            // The auth_url may or may not already include the /v3 prefix
            // (in-cluster: http://keystone:5000 ; public: https://k/v3). Append
            // only what's missing so we never produce /v3/v3/auth/tokens (404).
            let tokenPath = base.hasSuffix("/v3") ? "\(base)/auth/tokens" : "\(base)/v3/auth/tokens"
            if ProcessInfo.processInfo.environment["PROVISION_DEBUG"] != nil {
                FileHandle.standardError.write("PROVISION_DEBUG mint url: \(tokenPath)\n".data(using: .utf8)!)
            }
            // Run the mint + token extraction as a shell pipeline so the
            // X-Subject-Token header is parsed by grep/awk/tr (bulletproof
            // against line-ending quirks) rather than by Swift string parsing.
            // The body is written to a temp file to avoid any shell-quoting of
            // the password; curl reads it with --data @file.
            let bodyFile = "/tmp/mint_body_\(UUID().uuidString).json"
            do { try body.write(toFile: bodyFile, atomically: true, encoding: .utf8) } catch {
                throw CLIError(message: "provision: could not write mint body: \(error)")
            }
            defer { try? FileManager.default.removeItem(atPath: bodyFile) }
            let shellCmd = """
            curl -sS -m 30 -D - -o /dev/null -X POST '\(tokenPath)' \
              -H 'Content-Type: application/json' --data @\(bodyFile) \
              | grep -i '^x-subject-token:' | head -n1 | awk '{print $2}' | tr -d '\\r\\n'
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", shellCmd]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = outPipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !output.isEmpty else {
                logger.error("curl mint failed", metadata: ["exit": .string(String(process.terminationStatus)), "output": .string(String(output.prefix(300)))])
                throw CLIError(message: "provision: curl token mint failed (exit \(process.terminationStatus))")
            }
            if ProcessInfo.processInfo.environment["PROVISION_DEBUG"] != nil {
                FileHandle.standardError.write("PROVISION_DEBUG mint token len: \(output.count) head: \(output.prefix(30))...\n".data(using: .utf8)!)
            }
            return output
        }
    }

    /// Extract the minted token id from a block of HTTP response headers
    /// (the `X-Subject-Token` header). Robust to HTTP/1.1 vs HTTP/2 line
    /// endings (\n vs \r\n), header-name casing, and the header appearing
    /// anywhere in the text (e.g. mixed with stderr). Returns nil if the
    /// header is absent or empty.
    static func parseSubjectToken(fromHeaders headerText: String) -> String? {
        guard let lower = headerText.lowercased().range(of: "x-subject-token:") else {
            return nil
        }
        let afterColon = headerText[headerText.index(after: lower.upperBound)...]
        // Explicitly find the first line break (avoids any ambiguity in the
        // prefix(where:) overload resolution).
        var idx = afterColon.startIndex
        while idx < afterColon.endIndex {
            let c = afterColon[idx]
            if c == "\n" || c == "\r" { break }
            idx = afterColon.index(after: idx)
        }
        let token = String(afterColon[afterColon.startIndex..<idx])
            .trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Build a closure that runs an identity API request via a `curl`
    /// subprocess against `baseURL` (the cloud's auth_url, e.g. the in-cluster
    /// keystone svc). Used as the `ServiceProvisioner`'s identity client: some
    /// Keystones (Apache/mod_wsgi-fronted, e.g. Genestack/RDO) return responses
    /// the in-process AsyncHTTPClient fails to parse (`invalidHeaderFieldValues`)
    /// for authenticated calls, while curl handles them reliably. The request
    /// sends `token` (or none when empty) as X-Auth-Token, appends `query`
    /// items, and POSTs/PUTs `body` when present. Returns (status, body).
    static func curlIdentityClient(
        baseURL: String,
        logger: Logger
    ) -> (String, String, [URLQueryItem], String?, String?) async throws -> (status: Int, body: Data) {
        // Strip a trailing slash so `base + "/v3/..."` never double-slashes.
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return { method, path, query, body, token in
            var url = base
            if path.hasPrefix("/") {
                url = base + path
            } else {
                url = base + "/" + path
            }
            // Append query items (URL-encoded).
            if !query.isEmpty {
                var comps = URLComponents(string: url)
                comps?.queryItems = query
                url = comps?.string ?? url
            }
            var args: [String] = ["-sS", "-m", "30", "-X", method,
                                   "-w", "\n__HTTPSTATUS__%{http_code}"]
            if let token, !token.isEmpty {
                args += ["-H", "X-Auth-Token: \(token)"]
            }
            if let body {
                args += ["-H", "Content-Type: application/json", "--data", body]
            }
            args.append(url)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = args
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = outPipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let raw = outPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: raw, as: UTF8.self)
            if ProcessInfo.processInfo.environment["PROVISION_DEBUG"] != nil {
                FileHandle.standardError.write("PROVISION_DEBUG curlIdentity url: \(url) method: \(method) tokenLen: \((token ?? "").count) exit: \(process.terminationStatus) textLen: \(text.count) tail: \(String(text.suffix(80)))\n".data(using: .utf8)!)
            }
            // Split off the trailing "\n__HTTPSTATUS__<code>" marker.
            guard let marker = text.range(of: "\n__HTTPSTATUS__") else {
                throw CLIError(message: "provision: curl identity request missing status marker (output: \(text.prefix(300)))")
            }
            let bodyStr = String(text[text.startIndex..<marker.lowerBound])
            let codeStr = text[text.index(after: marker.upperBound)...].trimmingCharacters(in: .whitespaces)
            guard let status = Int(codeStr) else {
                throw CLIError(message: "provision: curl identity request bad status '\(codeStr)'")
            }
            if process.terminationStatus != 0 {
                logger.error("curl identity request failed", metadata: ["method": .string(method), "path": .string(path), "exit": .string(String(process.terminationStatus)), "status": .string(String(status))])
            }
            return (status: status, body: Data(bodyStr.utf8))
        }
    }
}

// MARK: - wait-secret (blocks until a key appears in a k8s Secret)
//
// Used as the provisioner Job's sidecar: after the Job's main container
// (kustomize) writes the app-cred Secret, this blocks until the Secret (or a
// specific key) exists, so the Job does not report success prematurely.
struct WaitSecretCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait-secret",
        abstract: "Block until a k8s Secret (and optionally a key) exists."
    )

    @Option(name: .long, help: "Name of the Secret to wait for.") var name: String
    @Option(name: .long, help: "Key that must be present (optional).") var key: String?
    @Option(name: .long, help: "Namespace (defaults to the pod's namespace).") var namespace: String?
    @Option(name: .long, help: "Poll interval seconds.") var interval: Double = 2
    @Option(name: .long, help: "Timeout seconds (0 = no timeout).") var timeout: Double = 300

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let ns = namespace ?? env["POD_NAMESPACE"] ?? "default"
        let tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        let caPath = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

        let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : nil
        while true {
            if let (present, hasKey) = try? await fetchSecret(name: name, key: key, namespace: ns, tokenPath: tokenPath, caPath: caPath),
               present && (key == nil || hasKey) {
                print("secret \(ns)/\(name) ready")
                return
            }
            if let d = deadline, Date() >= d {
                throw CLIExit(code: 1, message: "wait-secret: timed out after \(Int(timeout))s waiting for \(ns)/\(name)\(key.map { "/\($0)" } ?? "")")
            }
            try await Task.sleep(for: .seconds(interval))
        }
    }

    /// GET the Secret via the in-cluster ServiceAccount token. Returns
    /// (present, hasKey). Throws on transport/parse failure (caught by the
    /// caller's `try?`).
    private func fetchSecret(name: String, key: String?, namespace: String, tokenPath: String, caPath: String) async throws -> (present: Bool, hasKey: Bool) {
        let token = try String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { _ = try? await elg.shutdownGracefully() }
        let client = HTTPClient(eventLoopGroupProvider: .shared(elg))
        defer { _ = try? await client.shutdown() }

        let url = "https://kubernetes.default.svc/api/v1/namespaces/\(namespace)/secrets/\(name)"
        var req = try HTTPClient.Request(url: url, method: .GET)
        req.headers.add(name: "Authorization", value: "Bearer \(token)")
        req.headers.add(name: "Accept", value: "application/json")

        let response = try await client.execute(request: req, deadline: .now() + .seconds(10)).get()
        let data = response.body.flatMap { Data(buffer: $0) } ?? Data()
        guard response.status.code == 200 else {
            return (false, false)
        }
        struct SecretData: Decodable { let data: [String: String]? }
        guard let sd = try? JSONDecoder().decode(SecretData.self, from: data) else {
            return (false, false)
        }
        return (true, key.map { sd.data?[ $0 ] != nil } ?? false)
    }
}

// MARK: - write-secret (upsert a k8s Secret from a JSON result)
//
// Used by the provisioner Job: after `provision` prints its JSON result, this
// writes the app-cred (and other fields) into the `<fullname>-service-identity`
// Secret. It PRESERVES an existing `app_cred_secret` when the new result has no
// secret (i.e. the app-cred was reused and its secret is not recoverable).
struct WriteSecretCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write-secret",
        abstract: "Upsert a k8s Secret's string data from a JSON result (preserves an existing app_cred_secret when the new result omits it)."
    )

    @Option(name: .long, help: "Name of the Secret to write.") var name: String
    @Option(name: .long, help: "Namespace (defaults to the pod's namespace).") var namespace: String?
    @Argument(help: "The JSON result to write (each top-level key becomes a Secret string key).") var json: String

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let ns = namespace ?? env["POD_NAMESPACE"] ?? "default"

        struct Result: Decodable {
            let user_id: String?
            let username: String?
            let domain: String?
            let app_cred_id: String?
            let app_cred_name: String?
            let app_cred_secret: String?
            let app_cred_secret_created: Bool?
            let user_reused: Bool?
            let app_cred_reused: Bool?
        }
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(Result.self, from: data) else {
            throw CLIExit(code: 1, message: "write-secret: could not parse the JSON result")
        }

        // Build the desired string data (skip nils / empty secrets).
        var desired: [String: String] = [:]
        if let v = result.user_id, !v.isEmpty { desired["user_id"] = v }
        if let v = result.username, !v.isEmpty { desired["username"] = v }
        if let v = result.domain, !v.isEmpty { desired["domain"] = v }
        if let v = result.app_cred_id, !v.isEmpty { desired["app_cred_id"] = v }
        if let v = result.app_cred_name, !v.isEmpty { desired["app_cred_name"] = v }
        if let v = result.app_cred_secret, !v.isEmpty { desired["app_cred_secret"] = v }

        // Read the existing secret (if any) to preserve app_cred_secret when the
        // app-cred was reused (new result has no secret).
        if desired["app_cred_secret"] == nil,
           let existing = try? await readSecretString(name: name, namespace: ns),
           let prev = existing["app_cred_secret"] {
            desired["app_cred_secret"] = prev
        }

        try await putSecret(name: name, namespace: ns, data: desired)
        print("wrote secret \(ns)/\(name) (\(desired.count) keys)")
    }
}

// MARK: - mark-secret (set a single key in a k8s Secret)
//
// Used by the provisioner Job to flip `<fullname>-clouds` `provisioned: "true"`
// after the identity is written, which changes the clouds.yaml Secret's
// checksum and rolls the Deployment (now that it can carry the app-cred).
struct MarkSecretCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mark-secret",
        abstract: "Set a single key in a k8s Secret (preserving other keys)."
    )

    @Option(name: .long, help: "Name of the Secret to update.") var name: String
    @Option(name: .long, help: "Namespace (defaults to the pod's namespace).") var namespace: String?
    @Option(name: .long, help: "Key to set.") var key: String
    @Option(name: .long, help: "Value to set.") var value: String

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let ns = namespace ?? env["POD_NAMESPACE"] ?? "default"

        // Read existing data so we preserve all other keys (e.g. clouds.yaml).
        var existing = (try? await readSecretString(name: name, namespace: ns)) ?? [:]
        existing[key] = value
        try await putSecret(name: name, namespace: ns, data: existing)
        print("marked secret \(ns)/\(name) [\(key)=\(value)]")
    }
}

// MARK: - shared k8s Secret helpers (in-cluster, via the SA token)

/// Read a k8s Secret's data (base64-decoded) as [String: String].
func readSecretString(name: String, namespace: String) async throws -> [String: String] {
    let (present, data) = try await fetchSecretData(name: name, namespace: namespace)
    guard present else { return [:] }
    var out: [String: String] = [:]
    for (k, v) in data {
        if let d = Data(base64Encoded: v), let s = String(data: d, encoding: .utf8) {
            out[k] = s
        }
    }
    return out
}

/// PUT/POST a k8s Secret (string data). Creates if absent, updates if present.
func putSecret(name: String, namespace: String, data: [String: String]) async throws {
    let tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    let token = try String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

    // base64-encode the string data (k8s Secret .data is base64).
    var b64: [String: String] = [:]
    for (k, v) in data {
        b64[k] = Data(v.utf8).base64EncodedString()
    }

    let base = "https://kubernetes.default.svc/api/v1/namespaces/\(namespace)/secrets"
    let exists = (try? await fetchSecretData(name: name, namespace: namespace).0) ?? false

    let payload: String
    if exists {
        // PATCH (merge) so we don't clobber resourceVersion.
        payload = """
        {"data":\(try jsonDict(b64))}
        """
    } else {
        payload = """
        {"apiVersion":"v1","kind":"Secret","metadata":{"name":"\(name)","namespace":"\(namespace)"},"type":"Opaque","stringData":\(try jsonDict(data))}
        """
    }

    let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { _ = try? await elg.shutdownGracefully() }
    let client = HTTPClient(eventLoopGroupProvider: .shared(elg))
    defer { _ = try? await client.shutdown() }

    let method: HTTPMethod = exists ? .PATCH : .POST
    var req = try HTTPClient.Request(url: exists ? "\(base)/\(name)" : base, method: method)
    req.headers.add(name: "Authorization", value: "Bearer \(token)")
    req.headers.add(name: "Content-Type", value: "application/merge-patch+json")
    req.headers.add(name: "Accept", value: "application/json")
    req.body = .bytes([UInt8](payload.utf8))

    let response = try await client.execute(request: req, deadline: .now() + .seconds(15)).get()
    guard response.status.code == 200 || response.status.code == 201 else {
        let body = response.body.flatMap { String(decoding: Data(buffer: $0), as: UTF8.self) } ?? ""
        throw CLIExit(code: 1, message: "k8s secret write \(method) \(name) -> HTTP \(response.status.code): \(body)")
    }
}

/// Fetch a k8s Secret's raw .data (base64 map) via the SA token.
func fetchSecretData(name: String, namespace: String) async throws -> (present: Bool, data: [String: String]) {
    let tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    let token = try String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let url = "https://kubernetes.default.svc/api/v1/namespaces/\(namespace)/secrets/\(name)"

    let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { _ = try? await elg.shutdownGracefully() }
    let client = HTTPClient(eventLoopGroupProvider: .shared(elg))
    defer { _ = try? await client.shutdown() }

    var req = try HTTPClient.Request(url: url, method: .GET)
    req.headers.add(name: "Authorization", value: "Bearer \(token)")
    req.headers.add(name: "Accept", value: "application/json")
    let response = try await client.execute(request: req, deadline: .now() + .seconds(10)).get()
    let data = response.body.flatMap { Data(buffer: $0) } ?? Data()
    guard response.status.code == 200 else { return (false, [:]) }
    struct SecretData: Decodable { let data: [String: String]? }
    guard let sd = try? JSONDecoder().decode(SecretData.self, from: data) else { return (false, [:]) }
    return (true, sd.data ?? [:])
}

// MARK: - read-secret (print one key from a k8s Secret via the SA token)
//
// Used by the Deployment's initContainer to read the provisioned app-cred from
// the identity Secret (via the k8s API, not a volume mount — the Secret may not
// exist when the pod starts, and an optional Secret volume is not reliably
// populated in place). Prints the decoded value of `--key` to stdout.
struct ReadSecretCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read-secret",
        abstract: "Print one decoded key from a k8s Secret (in-cluster, via the SA token)."
    )

    @Option(name: .long, help: "Name of the Secret.") var name: String
    @Option(name: .long, help: "Key to print.") var key: String
    @Option(name: .long, help: "Namespace (defaults to the pod's namespace).") var namespace: String?

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let ns = namespace ?? env["POD_NAMESPACE"] ?? "default"
        let (present, data) = try await fetchSecretData(name: name, namespace: ns)
        guard present, let b64 = data[key],
              let decoded = Data(base64Encoded: b64),
              let value = String(data: decoded, encoding: .utf8) else {
            throw CLIExit(code: 1, message: "read-secret: key '\(key)' not found in \(ns)/\(name)")
        }
        print(value)
    }
}

/// Encode a [String: String] as a JSON object literal (for embedding in a body).
func jsonDict(_ dict: [String: String]) throws -> String {
    var out: [String: Any] = [:]
    for (k, v) in dict { out[k] = v }
    let data = try JSONSerialization.data(withJSONObject: out, options: [])
    return String(decoding: data, as: UTF8.self)
}

// MARK: - conformance (hidden; spec §14.5 conformance-HTTP-smoke)
//
// Drives the FULL MCP Streamable-HTTP handshake against a running server with
// the binary itself as the HTTP client (no curl, which is absent from the
// ubi10-minimal runtime). Hidden from --help (not added to the user-facing
// subcommand documentation). Mints a token against Keystone, then:
//   initialize -> tools/list -> tools/call os_whoami -> DELETE, asserting each
//   response; also asserts the 401 challenge on an unauthenticated request and
//   the PRM document shape. Exit 0 on all-pass, 1 on any failure.

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ConformanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conformance",
        abstract: "Conformance HTTP smoke (internal).",
        shouldDisplay: false
    )

    @Option(name: .long, help: "MCP endpoint base URL, e.g. http://127.0.0.1:8080/v1") var url: String
    @Option(name: .long, help: "Keystone token id (Bearer) to use.") var token: String?
    @Option(name: .long, help: "Keystone auth URL to mint a token if --token is unset.") var authURL: String?
    @Option(name: .long, help: "App credential id (mint).") var appCredID: String?
    @Option(name: .long, help: "App credential secret (mint).") var appCredSecret: String?
    @Flag(name: .long, help: "Expect a read-only (12-tool) tools/list instead of 18.") var readOnly: Bool = false

    struct Step: Sendable {
        let name: String
        let ok: Bool
        let detail: String
    }

    func run() async throws {
        let tokenID: String
        if let t = token {
            tokenID = t
        } else {
            tokenID = await mintToken()
        }

        let endpoint = url.hasSuffix("/") ? String(url.dropLast()) : url
        let steps = await ConformanceRunner(
            endpoint: endpoint,
            tokenID: tokenID,
            expectReadOnly: readOnly
        ).run()

        var allPass = true
        for s in steps {
            let mark = s.ok ? "PASS" : "FAIL"
            if !s.ok { allPass = false }
            print("[\(mark)] \(s.name)\(s.ok ? "" : " — \(s.detail)")")
        }
        print(allPass ? "CONFORMANCE: PASS" : "CONFORMANCE: FAIL")
        Foundation.exit(allPass ? 0 : 1)
    }

    private func mintToken() async -> String {
        guard let authURL, let id = appCredID, let secret = appCredSecret else {
            FileHandle.standardError.write(Data("conformance: need --token, or --auth-url + --app-cred-id + --app-cred-secret\n".utf8))
            Foundation.exit(2)
        }
        let body = """
        {"auth":{"identity":{"methods":["application_credential"],"application_credential":{"id":"\(id)","secret":"\(secret)"}},"scope":{"type":"project","project":{"domain":{"name":"default"}}}}}
        """
        do {
            var request = URLRequest(url: URL(string: authURL + "/auth/tokens")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let tok = json?["token"] as? [String: Any]
            if let id = tok?["id"] as? String { return id }
        } catch {}
        FileHandle.standardError.write(Data("conformance: token mint failed\n".utf8))
        // exit(1) is @noreturn; the function's return is satisfied by the
        // `return id` above plus this terminating call.
        Foundation.exit(1)
    }
}

/// The conformance handshake runner. Uses `URLSession` as a minimal HTTP
/// client so the binary needs no other HTTP dependency.
struct ConformanceRunner {
    let endpoint: String
    let tokenID: String
    let expectReadOnly: Bool

    func run() async -> [ConformanceCommand.Step] {
        var steps: [ConformanceCommand.Step] = []
        steps.append(await Self.step401Challenge(endpoint: endpoint))
        steps.append(await Self.stepPRM(endpoint: endpoint))
        let handshake = await Self.handshake(endpoint: endpoint, tokenID: tokenID, expectReadOnly: expectReadOnly)
        steps.append(contentsOf: handshake)
        return steps
    }

    /// A request with no Authorization header must get 401 + a Bearer challenge.
    private static func step401Challenge(endpoint: String) async -> ConformanceCommand.Step {
        let (status, headers, _) = await raw(endpoint: endpoint, method: "POST", token: nil, sessionID: nil, body: "")
        let www = headers["www-authenticate"] ?? ""
        let ok = status == 401 && www.contains("invalid_token")
        return .init(name: "401 challenge on unauthenticated request", ok: ok, detail: "status=\(status) www=\(www)")
    }

    /// The PRM document must carry the RFC 9728 keys.
    private static func stepPRM(endpoint: String) async -> ConformanceCommand.Step {
        let base = endpoint.hasSuffix("/v1") ? String(endpoint.dropLast(3)) : endpoint
        let (status, _, body) = await raw(endpoint: base + "/.well-known/oauth-protected-resource", method: "GET", token: nil, sessionID: nil, body: "")
        let hasKeys = body.contains("authorization_servers") && body.contains("resource") && body.contains("scopes_supported")
        let ok = status == 200 && hasKeys
        return .init(name: "PRM document (resource/authorization_servers/scopes_supported)", ok: ok, detail: "status=\(status) keys=\(hasKeys)")
    }

    private static func handshake(endpoint: String, tokenID: String, expectReadOnly: Bool) async -> [ConformanceCommand.Step] {
        var steps: [ConformanceCommand.Step] = []

        // 1. initialize -> 200 + MCP-Session-Id.
        let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"conformance","version":"1"}}}"#
        let (initStatus, initHeaders, initResp) = await raw(endpoint: endpoint, method: "POST", token: tokenID, sessionID: nil, body: initBody)
        let sessionID = initHeaders["mcp-session-id"]
        let initOk = initStatus == 200 && sessionID != nil && initResp.contains("protocolVersion")
        steps.append(.init(name: "initialize (200 + MCP-Session-Id)", ok: initOk, detail: "status=\(initStatus) session=\(sessionID ?? "nil")"))

        guard let sid = sessionID else {
            steps.append(.init(name: "tools/list", ok: false, detail: "no session id from initialize"))
            return steps
        }

        // 2. tools/list -> 200, 12 (read-only) or 18 (write) tools.
        // The 15 verb tools + 3 task-lifecycle tools (os_task_submit/status/
        // cancel, the Path C shim). Read-only sees the 9 read verbs + the 3
        // read-scoped task tools.
        let listBody = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        let (listStatus, _, listResp) = await raw(endpoint: endpoint, method: "POST", token: tokenID, sessionID: sid, body: listBody)
        let expectedCount = expectReadOnly ? 12 : 18
        let toolNames = ["os_list","os_get","os_describe","os_topology","os_find","os_whoami","os_quota","os_clouds","os_wait","os_create","os_update","os_delete","os_action","os_attach","os_detach","os_task_submit","os_task_status","os_task_cancel"]
        let present = toolNames.filter { listResp.contains("\"\($0)\"") }
        let listOk = listStatus == 200 && present.count == expectedCount
        steps.append(.init(name: "tools/list (\(expectedCount) tools)", ok: listOk, detail: "status=\(listStatus) found=\(present.count)/\(expectedCount)"))

        // 3. tools/call os_whoami -> 200, isError not true.
        let whoamiBody = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"os_whoami","arguments":{}}}"#
        let (callStatus, _, callResp) = await raw(endpoint: endpoint, method: "POST", token: tokenID, sessionID: sid, body: whoamiBody)
        // A successful tools/call returns a JSON-RPC "result" with content; it
        // does NOT echo the tool name. So assert on the result envelope, not the
        // literal name (earlier versions wrongly required "os_whoami" in the
        // body, which a valid response never contains).
        let whoamiOk = callStatus == 200
            && !callResp.contains(#"isError":true"#)
            && (callResp.contains(#""result""#) || callResp.contains(#""content""#))
        steps.append(.init(name: "tools/call os_whoami", ok: whoamiOk, detail: "status=\(callStatus)"))

        // 4. DELETE -> 200, terminates the session.
        let (delStatus, _, _) = await raw(endpoint: endpoint, method: "DELETE", token: tokenID, sessionID: sid, body: "")
        let delOk = delStatus == 200
        steps.append(.init(name: "DELETE (terminate session)", ok: delOk, detail: "status=\(delStatus)"))

        return steps
    }

    /// A minimal HTTP request returning (status, lowercased headers, body).
    private static func raw(endpoint: String, method: String, token: String?, sessionID: String?, body: String) async -> (Int, [String: String], String) {
        guard let url = URL(string: endpoint) else {
            return (0, [:], "bad url \(endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        if !body.isEmpty { request.httpBody = Data(body.utf8) }

        let (status, headers, responseBody) = await withCheckedContinuation { (cont: CheckedContinuation<(Int, [String: String], String), Never>) in
            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                let http = response as? HTTPURLResponse
                var h: [String: String] = [:]
                if let allHeaders = http?.allHeaderFields {
                    for (k, v) in allHeaders {
                        if let key = k as? String { h[key.lowercased()] = "\(v)" }
                    }
                }
                let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                cont.resume(returning: (http?.statusCode ?? 0, h, text))
            }
            task.resume()
        }
        return (status, headers, responseBody)
    }
}

/// Resolve the cloud entry to use, honoring `--cloud`, `clouds.default`, and
/// the single-cloud fallback (spec §11.4).
func resolveCloud(cfg: OpenStackMCPConfig, name: String?, logger: Logger) throws -> CloudEntry {
    let cloudsURL = cfg.cloudsFile.flatMap { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["OS_CLIENT_CONFIG_FILE"] ?? "clouds.yaml")
    let cloudConfig = CloudConfig.load(file: cloudsURL)

    let wanted = name
        ?? cfg.cloudsDefault
        ?? (cloudConfig.clouds.count == 1 ? cloudConfig.clouds[0].name : nil)
    guard let wanted, let entry = cloudConfig.cloud(named: wanted) else {
        let names = cloudConfig.clouds.map { $0.name }.joined(separator: ", ")
        throw CLIError(message: "Could not resolve cloud (tried: \(wanted ?? "<none>"). Known: \(names))")
    }
    return entry
}
