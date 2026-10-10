import Foundation
import Crypto

/// A structured, distro-aware provisioning payload for a compute server.
///
/// This is the semantic layer that sits *above* raw `user_data`: instead of
/// the LLM hand-authoring cloud-init YAML, it fills this small, secret-safe
/// DSL and the server renders a canonical cloud-init NoCloud document. The
/// rendered document is the *only* in-band provisioning mechanism (there is no
/// SSH/agent on these clouds), and it embeds console markers that
/// `CloudInitParser` reads back through the serial console to verify the work
/// actually landed.
///
/// Design constraints (see HANDOFF / provisioning design):
/// - **Deterministic**: a pure function of `(spec, distro)` → YAML, so it is
///   trivially testable, idempotent, and auditable.
/// - **Secret-safe**: no field accepts passwords/keys. Anything that needs one
///   is out of scope for phase 1 (the model uses the keypair story instead).
/// - **Bounded**: the renderer enforces `CloudInitRenderer.maxSize` so an
///   oversized spec is rejected before it hits Nova's user_data limit.
public struct ProvisioningSpec: Sendable, Codable, Equatable {

    /// A user to create via cloud-init's native `users:` section.
    ///
    /// Note: SSH key access for the *primary* login user is handled by Nova's
    /// `key_name` (server-level), not here. This primitive creates additional
    /// users with a shell and optional sudo. Phase 1 does not place key
    /// material in the spec (no secrets).
    public struct User: Sendable, Codable, Equatable {
        public var name: String
        public var shell: String?
        public var sudo: Bool

        public init(name: String, shell: String? = nil, sudo: Bool = false) {
            self.name = name
            self.shell = shell
            self.sudo = sudo
        }
    }

    /// A single firewall port to open via nftables/iptables in runcmd.
    public struct FirewallRule: Sendable, Codable, Equatable {
        public var proto: String
        public var port: Int

        public init(proto: String, port: Int) {
            self.proto = proto
            self.port = port
        }

        public var description: String { "\(proto)/\(port)" }
    }

    /// Package names to install (resolved per-distro by the renderer).
    public var packages: [String]
    /// Systemd services to `systemctl enable` (and start) after install.
    public var services: [String]
    /// Users to create.
    public var users: [User]
    /// Firewall ports to open.
    public var firewall: [FirewallRule]
    /// Escape-hatch shell lines appended to runcmd verbatim. Used for the
    /// long tail the primitives don't cover. These are NOT secret-checked
    /// beyond the "no arbitrary write_files" rule.
    public var extraRuncmd: [String]
    /// Optional message written to `/etc/motd.d/99-osmcp` (visible at login).
    public var finalMessage: String?

    public init(
        packages: [String] = [],
        services: [String] = [],
        users: [User] = [],
        firewall: [FirewallRule] = [],
        extraRuncmd: [String] = [],
        finalMessage: String? = nil
    ) {
        self.packages = packages
        self.services = services
        self.users = users
        self.firewall = firewall
        self.extraRuncmd = extraRuncmd
        self.finalMessage = finalMessage
    }

    /// True when nothing would be done (so the resolver can reject an
    /// empty `provisioning` block with a clear 400).
    public var isEmpty: Bool {
        packages.isEmpty && services.isEmpty && users.isEmpty && firewall.isEmpty
            && extraRuncmd.isEmpty && finalMessage == nil
    }
}

extension ProvisioningSpec {
    /// Decode a spec from a plain JSON object in the shape the MCP tool
    /// arguments arrive as (already converted from the MCP layer's JSONValue
    /// to a Swift dictionary of JSON scalars/arrays/objects).
    ///
    /// The resolver owns the `JSONValue` → `[String: Any]` bridge; this keeps
    /// the Provisioning module free of a dependency on the MCP layer.
    ///
    /// - Throws: `RenderDecodingError` with a precise field-level message so
    ///   the model can self-correct in one turn.
    public static func from(dict: [String: Any]) throws -> ProvisioningSpec {
        var packages: [String] = []
        if let v = dict["packages"] {
            guard let arr = v as? [Any] else { throw RenderDecodingError.wrongType("[string]", path: "packages") }
            for e in arr {
                guard let s = e as? String else { throw RenderDecodingError.wrongType("string (in array)", path: "packages") }
                packages.append(s)
            }
        }

        var services: [String] = []
        if let v = dict["services"] {
            guard let arr = v as? [Any] else { throw RenderDecodingError.wrongType("[string]", path: "services") }
            for e in arr {
                guard let s = e as? String else { throw RenderDecodingError.wrongType("string (in array)", path: "services") }
                services.append(s)
            }
        }

        var users: [User] = []
        if let v = dict["users"] {
            guard let arr = v as? [Any] else { throw RenderDecodingError.wrongType("[object]", path: "users") }
            for (i, e) in arr.enumerated() {
                guard let u = e as? [String: Any] else {
                    throw RenderDecodingError.wrongType("object (in array)", path: "users[\(i)]")
                }
                guard let name = u["name"] as? String else {
                    throw RenderDecodingError.missingField("users[\(i)].name")
                }
                let shell = u["shell"] as? String
                var sudo = false
                if let s = u["sudo"] {
                    guard let b = s as? Bool else {
                        throw RenderDecodingError.wrongType("boolean", path: "users[\(i)].sudo")
                    }
                    sudo = b
                }
                users.append(User(name: name, shell: shell, sudo: sudo))
            }
        }

        var firewall: [FirewallRule] = []
        if let v = dict["firewall"] {
            guard let arr = v as? [Any] else { throw RenderDecodingError.wrongType("[object]", path: "firewall") }
            for (i, e) in arr.enumerated() {
                guard let f = e as? [String: Any] else {
                    throw RenderDecodingError.wrongType("object (in array)", path: "firewall[\(i)]")
                }
                guard let proto = f["proto"] as? String, let port = f["port"] as? Int else {
                    throw RenderDecodingError.missingField("firewall[\(i)].proto / firewall[\(i)].port")
                }
                firewall.append(FirewallRule(proto: proto, port: port))
            }
        }

        var extraRuncmd: [String] = []
        if let v = dict["extra_runcmd"] ?? dict["extraRuncmd"] {
            guard let arr = v as? [Any] else { throw RenderDecodingError.wrongType("[string]", path: "extra_runcmd") }
            for e in arr {
                guard let s = e as? String else { throw RenderDecodingError.wrongType("string (in array)", path: "extra_runcmd") }
                extraRuncmd.append(s)
            }
        }

        var finalMessage: String?
        if let v = dict["final_message"] ?? dict["finalMessage"] {
            guard let s = v as? String else { throw RenderDecodingError.wrongType("string", path: "final_message") }
            finalMessage = s
        }

        return ProvisioningSpec(
            packages: packages,
            services: services,
            users: users,
            firewall: firewall,
            extraRuncmd: extraRuncmd,
            finalMessage: finalMessage
        )
    }
}

/// Decode errors surfaced when an MCP `provisioning` argument does not match
/// the `ProvisioningSpec` shape.
public enum RenderDecodingError: Error, Equatable {
    case missingField(String)
    case wrongType(String, path: String)

    public var description: String {
        switch self {
        case .missingField(let f):
            return "Provisioning spec is missing required field: \(f)"
        case .wrongType(let t, let p):
            return "Provisioning spec field '\(p)' is not a valid \(t)"
        }
    }
}

extension ProvisioningSpec {
    /// A deterministic 8-hex correlation token derived from the spec.
    ///
    /// The token appears in both the rendered cloud-init (as a comment) and the
    /// console transcript (`OSMCP_PROVISION_BEGIN <sha>`), so a reader can tie
    /// a console output back to the exact spec that produced it. It is NOT a
    /// cryptographic integrity guarantee — it is a stable, short fingerprint.
    ///
    /// The canonical form is built by concatenating each field's value in a
    /// fixed order, so the result is byte-identical across processes and
    /// platforms (no reliance on JSONEncoder key ordering).
    public var sha: String {
        Self.sha(for: self)
    }

    public static func sha(for spec: ProvisioningSpec) -> String {
        // Canonical string: fixed field order, arrays in stored order,
        // sub-objects sorted by a stable key.
        let users = spec.users
            .map { u in "\(u.name)|\(u.shell ?? "")|\(u.sudo)" }
            .sorted()
            .joined(separator: ";")
        let fw = spec.firewall
            .map { "\($0.proto)/\($0.port)" }
            .sorted()
            .joined(separator: ";")
        let canonical = [
            "pkgs=\(spec.packages.joined(separator: ","))",
            "svcs=\(spec.services.joined(separator: ","))",
            "users=\(users)",
            "fw=\(fw)",
            "runcmd=\(spec.extraRuncmd.joined(separator: ";"))",
            "msg=\(spec.finalMessage ?? "")",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
