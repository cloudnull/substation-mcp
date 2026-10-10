import Foundation

/// A detected (or forced) target distribution, with the concrete commands the
/// renderer uses to talk to it.
///
/// Distros are grouped by *family* because the renderer's command shape differs
/// by family, not by exact release:
/// - `apt` (debian, ubuntu, mint) — `apt-get install -y`, `ufw allow`
/// - `yum` (centos, rhel, rocky, alma, fedora) — `dnf install -y`, `firewalld`
/// - `unknown` — the renderer emits a *safe no-op* install (so the server still
///   boots and the provisioning block is a no-op) and surfaces the unknown
///   family in the result so the caller can decide.
public struct Distro: Sendable, Equatable {
    public enum Family: String, Sendable, Equatable, Codable {
        case apt
        case yum
        case unknown
    }

    public var family: Family
    /// Human-readable distro name (e.g. "ubuntu", "rhel"), for diagnostics.
    public var name: String

    public init(family: Family, name: String) {
        self.family = family
        self.name = name
    }
}

public extension Distro {
    static let debian = Distro(family: .apt, name: "debian")
    static let ubuntu = Distro(family: .apt, name: "ubuntu")
    static let fedora = Distro(family: .yum, name: "fedora")
    static let rhel = Distro(family: .yum, name: "rhel")
    static let centos = Distro(family: .yum, name: "centos")
    static let rocky = Distro(family: .yum, name: "rocky")
    static let alma = Distro(family: .yum, name: "alma")
    static let unknown = Distro(family: .unknown, name: "unknown")

    /// Detect a distro from image metadata.
    ///
    /// Priority:
    /// 1. Explicit `os_type` / `os_distro` image property (if present).
    /// 2. Glance `tags` (case-insensitive substring match against known names).
    /// 3. Image `name` (case-insensitive substring match).
    /// 4. Fallback: `.unknown`.
    ///
    /// `name` is the image name; `tags` and `properties` are the image's tag
    /// list and property map respectively. Any of them may be nil/empty — the
    /// detection degrades gracefully to `.unknown`.
    static func detect(name: String?, tags: [String]?, properties: [String: String]?) -> Distro {
        // 1. Explicit image property (authoritative when set).
        let explicit = (properties?["os_distro"] ?? properties?["os_type"])?.lowercased()
        if let explicit, let d = matchDistro(in: explicit) { return d }

        // 2. Glance tags.
        if let tags {
            for tag in tags {
                if let d = matchDistro(in: tag.lowercased()) { return d }
            }
        }

        // 3. Image name.
        if let name, let d = matchDistro(in: name.lowercased()) { return d }

        // 4. Unknown.
        return .unknown
    }

    /// Map a (already-lowercased) name/tag string to a Distro, or nil.
    private static func matchDistro(in s: String) -> Distro? {
        // Order matters: "ubuntu" is matched before "debian" because some
        // ubuntu images also tag "debian-compatible". Check the more specific
        // / branded names first.
        let table: [(String, Distro)] = [
            ("ubuntu", .ubuntu),
            ("debian", .debian),
            ("linuxmint", .debian), ("mint", .debian),
            ("centos", .centos),
            ("rhel", .rhel), ("red hat", .rhel), ("redhat", .rhel),
            ("rocky", .rocky),
            ("alma", .alma), ("almalinux", .alma),
            ("fedora", .fedora),
        ]
        for (needle, distro) in table where s.contains(needle) {
            return distro
        }
        return nil
    }
}
