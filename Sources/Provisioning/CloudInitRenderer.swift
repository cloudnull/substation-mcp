import Foundation

/// Renders a `ProvisioningSpec` (for a detected `Distro`) into a canonical
/// cloud-init NoCloud `user_data` document.
///
/// The document is fully deterministic (stable key order, no timestamps) so it
/// is idempotent, diffable, and unit-testable. It always carries the console
/// markers `OSMCP_PROVISION_BEGIN <sha>` / `OSMCP_PROVISION_END <sha> ok=<0|1>`
/// that `CloudInitParser` reads back from the serial console.
public enum CloudInitRenderer {
    /// Hard cap on rendered `user_data` size (plaintext bytes). Kept under
    /// Nova's 16 KiB limit; base64 inflates by ~4/3 so the resolver re-checks
    /// the encoded size as well.
    public static let maxSize = 12 * 1024

    /// An error from rendering, carrying the partial YAML when available so the
    /// caller can show the model exactly what it tried to build.
    public struct RenderError: Error, Equatable {
        public enum Kind: Equatable, Sendable {
            case oversized(size: Int, limit: Int)
            case emptySpec
        }
        public var kind: Kind
        /// The YAML that was built before the failure (nil for emptySpec).
        public var partial: String?

        public var description: String {
            switch kind {
            case .oversized(let size, let limit):
                return "Rendered cloud-init is \(size) bytes, exceeding the \(limit)-byte limit. Trim packages/services/users or use fewer extra_runcmd lines."
            case .emptySpec:
                return "Provisioning spec is empty: provide at least one of packages, services, users, firewall, extra_runcmd, or final_message (or omit the provisioning block entirely)."
            }
        }
    }

    /// Render `spec` for `distro`.
    ///
    /// - Returns: the full `user_data` YAML (plaintext, starting with
    ///   `#cloud-config`).
    /// - Throws: `RenderError.oversized` if the result exceeds `maxSize`,
    ///   `RenderError.emptySpec` if nothing would be done.
    public static func render(spec: ProvisioningSpec, distro: Distro) throws -> String {
        guard !spec.isEmpty else {
            throw RenderError(kind: .emptySpec, partial: nil)
        }
        let yaml = build(spec: spec, distro: distro)
        let size = yaml.utf8.count
        guard size <= maxSize else {
            throw RenderError(kind: .oversized(size: size, limit: maxSize), partial: yaml)
        }
        return yaml
    }

    /// Render + base64-encode in one call (the form Nova expects for
    /// `user_data`).
    public static func renderBase64(spec: ProvisioningSpec, distro: Distro) throws -> String {
        let yaml = try render(spec: spec, distro: distro)
        return Data(yaml.utf8).base64EncodedString()
    }
}

// MARK: - YAML build

private extension CloudInitRenderer {
    /// Assemble the full `#cloud-config` document.
    static func build(spec: ProvisioningSpec, distro: Distro) -> String {
        let sha = spec.sha
        var out: [String] = []
        out.append("#cloud-config")
        out.append("# OSMCP_PROVISIONING sha=\(sha) distro=\(distro.name)/\(distro.family.rawValue)")

        // --- write_files (only when a final message is present) ---
        if let message = spec.finalMessage, !message.isEmpty {
            out.append("write_files:")
            out.append("- path: /etc/motd.d/99-osmcp")
            out.append("  content: |")
            for line in message.components(separatedBy: "\n") {
                out.append("    \(line)")
            }
            out.append("  owner: root:root")
            out.append("  permissions: '0644'")
        }

        // --- user creation (native users: section) ---
        if !spec.users.isEmpty {
            out.append("users:")
            for u in spec.users.sorted(by: { $0.name < $1.name }) {
                let shell = u.shell ?? "/bin/bash"
                out.append("- name: \(yamlScalar(u.name))")
                out.append("  shell: \(yamlScalar(shell))")
                if u.sudo {
                    out.append("  sudo: 'ALL=(ALL) NOPASSWD:ALL'")
                    out.append("  groups: sudo,wheel")
                }
            }
        }

        // --- runcmd (all shell work, distro-aware) ---
        out.append("runcmd:")
        out.append("- [ sh, -c, '\(beginLine(sha))' ]")
        for line in workBlock(spec: spec, distro: distro) {
            out.append("- [ sh, -c, '\(line)' ]")
        }
        out.append("- [ sh, -c, '\(endLine(sha))' ]")

        return out.joined(separator: "\n")
    }

    /// The distro-aware "real work" runcmd lines. Each line is a single shell
    /// string executed via `sh -c`. The block tracks its worst exit code in
    /// `$PROVISION_RC` so the END marker reports a clean ok/!ok.
    static func workBlock(spec: ProvisioningSpec, distro: Distro) -> [String] {
        var lines: [String] = []
        lines.append("PROVISION_RC=0")
        lines.append("provision_one() { out=$(\"$@\" 2>&1); rc=$?; echo \"[osmcp-provision] $* -> rc=$rc\"; if [ $rc -ne 0 ]; then echo \"$out\"; PROVISION_RC=1; fi; }")

        // 1. Package install.
        if !spec.packages.isEmpty {
            switch distro.family {
            case .apt:
                let pkgs = spec.packages.map(shellQuote).joined(separator: " ")
                lines.append("provision_one env DEBIAN_FRONTEND=noninteractive apt-get update")
                lines.append("provision_one env DEBIAN_FRONTEND=noninteractive apt-get install -y \(pkgs)")
            case .yum:
                let pkgs = spec.packages.map(shellQuote).joined(separator: " ")
                lines.append("provision_one dnf install -y \(pkgs)")
            case .unknown:
                let pkgs = spec.packages.joined(separator: ", ")
                lines.append("echo \"[osmcp-provision] WARN: unknown distro '\(distro.name)', skipping package install for: \(pkgs)\"")
            }
        }

        // 2. Service enable + start.
        if !spec.services.isEmpty {
            for s in spec.services.sorted() {
                lines.append("provision_one systemctl enable \(shellQuote(s))")
                lines.append("provision_one systemctl start \(shellQuote(s))")
            }
        }

        // 3. Firewall.
        if !spec.firewall.isEmpty {
            let rules = spec.firewall.sorted { ($0.proto, $0.port) < ($1.proto, $1.port) }
            let ruleList = rules.map(\.description).joined(separator: ", ")
            switch distro.family {
            case .apt:
                let cmds = rules.map { "provision_one ufw allow \(shellQuote($0.description))" }.joined(separator: " ; ")
                lines.append("if command -v ufw >/dev/null 2>&1; then ufw --force enable >/dev/null 2>&1; \(cmds); else echo \"[osmcp-provision] WARN: ufw not available, skipping firewall: \(ruleList)\"; fi")
            case .yum:
                let cmds = rules.map { rule in
                    let p = rule.port == 0 ? "'0'" : shellQuote(String(rule.port))
                    return "provision_one firewall-cmd --permanent --add-port=\(p):\(shellQuote(rule.proto))"
                }.joined(separator: " ; ")
                lines.append("if command -v firewall-cmd >/dev/null 2>&1; then systemctl enable --now firewalld >/dev/null 2>&1; \(cmds) ; provision_one firewall-cmd --reload; else echo \"[osmcp-provision] WARN: firewalld not available, skipping firewall: \(ruleList)\"; fi")
            case .unknown:
                lines.append("echo \"[osmcp-provision] WARN: unknown distro '\(distro.name)', skipping firewall for: \(ruleList)\"")
            }
        }

        // 4. Extra runcmd (escape hatch).
        for line in spec.extraRuncmd {
            lines.append("provision_one sh -c \(shellQuote(line))")
        }

        return lines
    }

    // MARK: - Markers

    static func beginLine(_ sha: String) -> String {
        "echo OSMCP_PROVISION_BEGIN \(sha)"
    }
    /// The END marker. `PROVISION_RC` is set in the parent runcmd shell, so we
    /// capture it into `OSMCP_OK` *in that shell* first, then echo it. (Reading
    /// the variable inside a `$( ... )` substitution would run in a subshell
    /// that does not see it and always report failure.)
    static func endLine(_ sha: String) -> String {
        "OSMCP_OK=$([ \"$PROVISION_RC\" -eq 0 ] && echo 1 || echo 0); echo OSMCP_PROVISION_END \(sha) ok=$OSMCP_OK"
    }

    // MARK: - Escaping helpers

    /// Single-quote a string for use as a shell argument (POSIX safe).
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Minimal YAML scalar quoting: bare for simple identifiers, double-quoted
    /// otherwise. Keeps the output readable and valid.
    static func yamlScalar(_ s: String) -> String {
        func isSimpleScalar(_ c: Character) -> Bool {
            if c.isLetter || c.isNumber { return true }
            return c == "-" || c == "_" || c == "." || c == "/"
        }
        if s.allSatisfy(isSimpleScalar) && !s.isEmpty {
            return s
        }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
