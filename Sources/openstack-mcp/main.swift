import ArgumentParser
import Foundation
import Hummingbird
import HummingbirdMCP
import Logging
import MCP
import OpenStackClient
import OpenStackMCPServer

// MARK: - Top-level CLI (spec §11.3)

/// OpenStack MCP server.
struct OpenStackMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "openstack-mcp",
        abstract: "Expose an OpenStack cloud as an MCP server.",
        subcommands: [
            ServeCommand.self,
            StdioCommand.self,
            HealthzCommand.self,
        ],
        defaultSubcommand: nil
    )
}

// MARK: - serve (spec §11.3, §7.1)

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
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

        logger.info("openstack-mcp serving", metadata: [
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
        let factory = wiring.makeServerFactory(policy: policy, logger: logger)
        let server = await factory(identity)

        let transport = StdioTransport(logger: nil)
        logger.info("openstack-mcp running over stdio", metadata: [
            "cloud": "\(cloudEntry.name)",
            "project": "\(vt.token.project.id)",
        ])
        try await server.start(transport: transport)
        // Block until the transport's read loop finishes (EOF on stdin).
        await transport.disconnect()
        try await server.stop()
    }
}

// MARK: - healthz (spec §11.3)

struct HealthzCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print liveness JSON and exit 0.")

    func run() throws {
        print(#"{"alive":true}"#)
    }
}

struct CLIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
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
