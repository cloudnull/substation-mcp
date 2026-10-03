import Foundation
import MCP
import OpenStackClient

/// MCP prompt surface (spec §9): named prompt templates that expand into
/// ordered tool-call plans the model executes. Phase 1 ships four prompts:
/// `login`, `provision_server`, `diagnose_connectivity`, `audit_security_groups`.
public struct MCPPrompts: Sendable {
    let registry: ToolRegistry

    public init(registry: ToolRegistry) {
        self.registry = registry
    }

    // MARK: - List

    public func list() -> [Prompt] {
        [
            Prompt(
                name: "login",
                title: "Get an OpenStack token",
                description: "How to authenticate: client-side mint instructions, or a URL-mode elicitation to the login page when the client supports elicitation.",
                arguments: [
                    Prompt.Argument(name: "cloud", title: "Cloud", description: "The cloud to authenticate against (optional).", required: false),
                ]
            ),
            Prompt(
                name: "provision_server",
                title: "Provision a server",
                description: "Ordered plan to provision a server, optionally with a public IP and an attached data volume.",
                arguments: [
                    Prompt.Argument(name: "name", title: "Name", description: "Server name.", required: true),
                    Prompt.Argument(name: "flavor", title: "Flavor", description: "Flavor id or name.", required: true),
                    Prompt.Argument(name: "image", title: "Image", description: "Image id or name.", required: true),
                    Prompt.Argument(name: "network", title: "Network", description: "Network id or name.", required: true),
                    Prompt.Argument(name: "public", title: "Public IP", description: "true to allocate and attach a floating IP.", required: false),
                    Prompt.Argument(name: "volume_gb", title: "Volume GB", description: "Size of an attached data volume, in GB.", required: false),
                ]
            ),
            Prompt(
                name: "diagnose_connectivity",
                title: "Diagnose connectivity",
                description: "Diagnose network connectivity between two endpoints on a given port/protocol.",
                arguments: [
                    Prompt.Argument(name: "from", title: "From", description: "The source server (id or name).", required: true),
                    Prompt.Argument(name: "to", title: "To", description: "The destination server or address (id, name, or IP).", required: true),
                    Prompt.Argument(name: "port", title: "Port", description: "The destination port.", required: true),
                    Prompt.Argument(name: "protocol", title: "Protocol", description: "The protocol (tcp, udp, icmp).", required: true),
                ]
            ),
            Prompt(
                name: "audit_security_groups",
                title: "Audit security groups",
                description: "List security groups with world-open ingress on sensitive ports and flag unused groups.",
                arguments: []
            ),
        ]
    }

    // MARK: - Get

    public func get(_ name: String, arguments: [String: String]?) -> (description: String?, messages: [Prompt.Message]) {
        switch name {
        case "login":
            return (loginDescription, [.user(.text(text: loginText(arguments?["cloud"])))])
        case "provision_server":
            return (provisionDescription, [.user(.text(text: provisionText(arguments)))])
        case "diagnose_connectivity":
            return (diagnoseDescription, [.user(.text(text: diagnoseText(arguments)))])
        case "audit_security_groups":
            return (auditDescription, [.user(.text(text: auditText))])
        default:
            return (nil, [.user(.text(text: "Unknown prompt: \(name). Valid prompts: \(list().map(\.name).joined(separator: ", "))"))])
        }
    }

    // MARK: - Template text

    private let loginDescription = "Instructions for authenticating to the cloud."
    private let provisionDescription = "Ordered plan to provision a server."
    private let diagnoseDescription = "Directs a connectivity diagnosis between two endpoints."
    private let auditDescription = "Directs a security-group audit."

    private func loginText(_ cloud: String?) -> String {
        let name = cloud ?? "<cloud>"
        return """
        Get an OpenStack token for this session.

        Client-side mint (preferred, no server round-trip):
        1. Mint a Keystone token using your application credential (or user + password + project).
        2. Store the token id at ~/.config/openstack/mcp-tokens/\(name).token with file mode 0600.
        3. Re-run this whenever a request returns 401 so the token is refreshed.

        If this client declared elicitation support, use the server's /v1/login page instead: the
        user enters their local credentials out-of-band and the server stores the minted token for
        this session.
        """
    }

    private func provisionText(_ arguments: [String: String]?) -> String {
        let a = arguments ?? [:]
        func arg(_ k: String) -> String { a[k] ?? "<\(k)>" }
        var lines: [String] = []
        lines.append("Provision a server named \"\(arg("name"))\" in this project. Execute these steps in order and stop at the first failure:")
        lines.append("1. Find the flavor, image, and network by name or id with os_find (or os_get):")
        lines.append("   - flavor: \(arg("flavor"))")
        lines.append("   - image: \(arg("image"))")
        lines.append("   - network: \(arg("network"))")
        lines.append("2. Create the server with os_create(resource: server) using the resolved flavor, image, and network ids (see os_describe(resource: server) for the create schema).")
        lines.append("3. Wait for the server to become ACTIVE with os_wait(resource: server, until: [\"ACTIVE\"]).")
        var step = 4
        if (a["public"] ?? "").lowercased() == "true" {
            lines.append("\(step). Create a floating IP with os_create(resource: floating_ip) and attach it to the server with os_attach(link: floating_ip).")
            step += 1
        }
        if (a["volume_gb"].map { !$0.isEmpty } ?? false) {
            lines.append("\(step). Create a volume of \(arg("volume_gb")) GB with os_create(resource: volume) and attach it to the server with os_attach(link: volume).")
        }
        lines.append("Report the server id, status, and any attached resources when finished.")
        return lines.joined(separator: "\n")
    }

    private func diagnoseText(_ arguments: [String: String]?) -> String {
        let a = arguments ?? [:]
        func arg(_ k: String) -> String { a[k] ?? "<\(k)>" }
        return """
        Diagnose whether "\(arg("from"))" can reach "\(arg("to"))" on port \(arg("port"))/\(arg("protocol")).

        1. Run os_topology on the source side: os_topology(resource: server, id_or_name: "\(arg("from"))", diagnosis: true).
        2. Run os_topology on the destination side: os_topology(resource: server, id_or_name: "\(arg("to"))", diagnosis: true).
        3. Compare the two topologies (both ends) and explain the first blocking finding — a port with port security enabled and no matching ingress rule, a subnet with no router interface, a router with no gateway, or a server in ERROR/SHUTOFF — in plain terms, and state what to change to unblock it.
        """
    }

    private let auditText = """
    Audit the security groups of this project:
    1. List security groups with os_list(resource: security_group).
    2. List their rules with os_list(resource: security_group_rule).
    3. Flag any ingress rule that allows 0.0.0.0/0 on a sensitive port (for example 22/SSH, 3389/RDP, or a database port), naming the group and rule.
    4. Flag security groups that have no ports (and no servers) attached as unused.
    Summarize the findings and recommend the smallest safe change for each.
    """
}
