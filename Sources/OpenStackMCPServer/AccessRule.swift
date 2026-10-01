import Foundation

// MARK: - Access rules (spec §11.3 `access-rules`)

/// One Keystone access rule: a (service, method, path) triple. `path` is
/// RELATIVE TO THE SERVICE ROOT as mounted in the Keystone catalog (what
/// keystonemiddleware compares against), using `*` for one segment and `**`
/// for many.
public struct Rule: Hashable, Codable, Sendable {
    public let service: String
    public let method: String
    public let path: String

    public init(service: String, method: String, path: String) {
        self.service = service
        self.method = method
        self.path = path
    }
}

/// The pinned, exact per-service access-rule path sets (spec §11.3). These are
/// the single source of truth: the `access-rules` generator and the tests both
/// reference these constants rather than re-hardcoding strings.
public enum AccessRulePaths {
    // MARK: compute (Nova) — paths relative to the Nova service root
    public static let compute: [Rule] = [
        r("compute", "GET", "/servers"),
        r("compute", "POST", "/servers"),
        r("compute", "GET", "/servers/*"),
        r("compute", "PATCH", "/servers/*"),
        r("compute", "DELETE", "/servers/*"),
        r("compute", "POST", "/servers/*/action"),
        r("compute", "GET", "/servers/*/os-volume_attachments"),
        r("compute", "POST", "/servers/*/os-volume_attachments"),
        r("compute", "DELETE", "/servers/*/os-volume_attachments/*"),
        r("compute", "GET", "/servers/*/os-interface"),
        r("compute", "POST", "/servers/*/os-interface"),
        r("compute", "DELETE", "/servers/*/os-interface/*"),
        r("compute", "GET", "/servers/detail"),
        r("compute", "GET", "/flavors"),
        r("compute", "POST", "/flavors"),
        r("compute", "GET", "/flavors/*"),
        r("compute", "DELETE", "/flavors/*"),
        r("compute", "GET", "/os-keypairs"),
        r("compute", "POST", "/os-keypairs"),
        r("compute", "DELETE", "/os-keypairs/*"),
        r("compute", "GET", "/os-server-groups"),
        r("compute", "POST", "/os-server-groups"),
        r("compute", "DELETE", "/os-server-groups/*"),
        r("compute", "GET", "/os-availability-zone"),
        r("compute", "GET", "/os-hypervisors"),
        r("compute", "GET", "/os-hypervisors/*"),
        r("compute", "GET", "/os-services"),
        r("compute", "PUT", "/os-services/*"),
        r("compute", "GET", "/os-quota-sets/*"),
        r("compute", "PUT", "/os-quota-sets/*"),
    ]

    // MARK: network (Neutron) — paths under /v2.0/
    public static let network: [Rule] = [
        r("network", "GET", "/v2.0/networks"),
        r("network", "POST", "/v2.0/networks"),
        r("network", "GET", "/v2.0/networks/*"),
        r("network", "PATCH", "/v2.0/networks/*"),
        r("network", "DELETE", "/v2.0/networks/*"),
        r("network", "GET", "/v2.0/subnets"),
        r("network", "POST", "/v2.0/subnets"),
        r("network", "GET", "/v2.0/subnets/*"),
        r("network", "PATCH", "/v2.0/subnets/*"),
        r("network", "DELETE", "/v2.0/subnets/*"),
        r("network", "GET", "/v2.0/ports"),
        r("network", "POST", "/v2.0/ports"),
        r("network", "GET", "/v2.0/ports/*"),
        r("network", "PATCH", "/v2.0/ports/*"),
        r("network", "DELETE", "/v2.0/ports/*"),
        r("network", "GET", "/v2.0/routers"),
        r("network", "POST", "/v2.0/routers"),
        r("network", "GET", "/v2.0/routers/*"),
        r("network", "PATCH", "/v2.0/routers/*"),
        r("network", "DELETE", "/v2.0/routers/*"),
        r("network", "PUT", "/v2.0/routers/*/add_router_interface"),
        r("network", "PUT", "/v2.0/routers/*/remove_router_interface"),
        r("network", "GET", "/v2.0/floatingips"),
        r("network", "POST", "/v2.0/floatingips"),
        r("network", "GET", "/v2.0/floatingips/*"),
        r("network", "PATCH", "/v2.0/floatingips/*"),
        r("network", "DELETE", "/v2.0/floatingips/*"),
        r("network", "GET", "/v2.0/security-groups"),
        r("network", "POST", "/v2.0/security-groups"),
        r("network", "GET", "/v2.0/security-groups/*"),
        r("network", "PATCH", "/v2.0/security-groups/*"),
        r("network", "DELETE", "/v2.0/security-groups/*"),
        r("network", "GET", "/v2.0/security-group-rules"),
        r("network", "POST", "/v2.0/security-group-rules"),
        r("network", "DELETE", "/v2.0/security-group-rules/*"),
        r("network", "GET", "/v2.0/quotas/*"),
        r("network", "PUT", "/v2.0/quotas/*"),
    ]

    /// Neutron `address-group` extension rules (emitted only when the
    /// `address-group` extension is present).
    public static let networkAddressGroup: [Rule] = [
        r("network", "GET", "/v2.0/address-groups"),
        r("network", "POST", "/v2.0/address-groups"),
        r("network", "GET", "/v2.0/address-groups/*"),
        r("network", "PATCH", "/v2.0/address-groups/*"),
        r("network", "DELETE", "/v2.0/address-groups/*"),
    ]

    // MARK: blockStorage (Cinder v3) — paths relative to the Cinder service root
    public static let blockStorage: [Rule] = [
        r("blockStorage", "GET", "/volumes"),
        r("blockStorage", "POST", "/volumes"),
        r("blockStorage", "GET", "/volumes/*"),
        r("blockStorage", "PATCH", "/volumes/*"),
        r("blockStorage", "DELETE", "/volumes/*"),
        r("blockStorage", "POST", "/volumes/*/extend"),
        r("blockStorage", "POST", "/volumes/*/retype"),
        r("blockStorage", "POST", "/volumes/*/reset_status"),
        r("blockStorage", "POST", "/volumes/*/upload_to_image"),
        r("blockStorage", "POST", "/volumes/*/set_bootable"),
        r("blockStorage", "GET", "/volumes/types"),
        r("blockStorage", "POST", "/volumes/types"),
        r("blockStorage", "GET", "/volumes/types/*"),
        r("blockStorage", "GET", "/volumes/snapshots"),
        r("blockStorage", "POST", "/volumes/snapshots"),
        r("blockStorage", "GET", "/volumes/snapshots/*"),
        r("blockStorage", "PATCH", "/volumes/snapshots/*"),
        r("blockStorage", "DELETE", "/volumes/snapshots/*"),
        r("blockStorage", "GET", "/volumes/backups"),
        r("blockStorage", "POST", "/volumes/backups"),
        r("blockStorage", "DELETE", "/volumes/backups/*"),
        r("blockStorage", "POST", "/volumes/backups/*/restore"),
        r("blockStorage", "GET", "/os-quota-sets/*"),
        r("blockStorage", "PUT", "/os-quota-sets/*"),
    ]

    // MARK: identity (Keystone v3) — paths relative to the Keystone service root
    public static let identity: [Rule] = [
        r("identity", "GET", "/projects"),
        r("identity", "POST", "/projects"),
        r("identity", "GET", "/projects/*"),
        r("identity", "PATCH", "/projects/*"),
        r("identity", "DELETE", "/projects/*"),
        r("identity", "GET", "/users"),
        r("identity", "POST", "/users"),
        r("identity", "GET", "/users/*"),
        r("identity", "PATCH", "/users/*"),
        r("identity", "DELETE", "/users/*"),
        r("identity", "GET", "/groups"),
        r("identity", "POST", "/groups"),
        r("identity", "GET", "/groups/*"),
        r("identity", "PATCH", "/groups/*"),
        r("identity", "DELETE", "/groups/*"),
        r("identity", "GET", "/roles"),
        r("identity", "POST", "/roles"),
        r("identity", "GET", "/roles/*"),
        r("identity", "PATCH", "/roles/*"),
        r("identity", "DELETE", "/roles/*"),
        r("identity", "POST", "/projects/*/users/*/roles/*"),
        r("identity", "DELETE", "/projects/*/users/*/roles/*"),
        r("identity", "GET", "/domains"),
        r("identity", "POST", "/domains"),
        r("identity", "GET", "/domains/*"),
        r("identity", "GET", "/services"),
        r("identity", "GET", "/endpoints"),
        r("identity", "GET", "/endpoints/*"),
        r("identity", "GET", "/users/*/application_credentials/*"),
        r("identity", "GET", "/regions"),
        r("identity", "GET", "/regions/*"),
    ]

    // MARK: image (Glance v2) — paths relative to the Glance service root
    public static let image: [Rule] = [
        r("image", "GET", "/images"),
        r("image", "POST", "/images"),
        r("image", "GET", "/images/*"),
        r("image", "PATCH", "/images/*"),
        r("image", "DELETE", "/images/*"),
        r("image", "PUT", "/images/*"),
        r("image", "GET", "/images/*/tags"),
        r("image", "POST", "/images/*/tags"),
        r("image", "DELETE", "/images/*/tags/*"),
    ]

    private static func r(_ s: String, _ m: String, _ p: String) -> Rule {
        Rule(service: s, method: m, path: p)
    }
}

/// Generates the JSON list of access rules Keystone expects, for a given mode
/// and service/resource subset (spec §11.3 `access-rules`).
public enum AccessRulesGenerator {
    /// The service keys in a stable, documented order.
    public static let serviceOrder = ["compute", "network", "blockStorage", "identity", "image"]

    /// All rules for a mode, optionally filtered by service and resource.
    ///
    /// - `readOnly` → only `GET` methods (Keystone rules use the method as-is;
    ///   HEAD is emitted as GET and pinned to GET only).
    /// - `services` → restrict to these service keys (nil/empty = all).
    /// - `resources` → remove these resources' paths (nil/empty = keep all).
    ///   A resource maps to a set of path prefixes within its service.
    /// - `neutronExtensions` → when it contains `"address-group"`, the
    ///   address-group network rules are included.
    public static func generate(
        readOnly: Bool,
        services: Set<String>? = nil,
        resources: Set<String>? = nil,
        neutronExtensions: Set<String> = []
    ) -> [Rule] {
        var all: [Rule] = []
        all += AccessRulePaths.compute
        all += AccessRulePaths.network
        if neutronExtensions.contains("address-group") {
            all += AccessRulePaths.networkAddressGroup
        }
        all += AccessRulePaths.blockStorage
        all += AccessRulePaths.identity
        all += AccessRulePaths.image

        var filtered = all
        if readOnly {
            filtered = filtered.filter { $0.method == "GET" }
        }
        if let services, !services.isEmpty {
            filtered = filtered.filter { services.contains($0.service) }
        }
        if let resources, !resources.isEmpty {
            // Remove rules whose first path segment maps to an excluded
            // resource; rules that don't map to a filterable resource stay.
            filtered = filtered.filter { rule in
                guard let res = resourceForPath(rule.path) else { return true }
                return !resources.contains(res)
            }
        }
        return filtered
    }

    /// Render the rule list as the JSON object Keystone's
    /// `openstack application credential create --access-rules` expects:
    /// `{"rules":[{service,method,path},...]}`.
    public static func json(
        readOnly: Bool,
        services: Set<String>? = nil,
        resources: Set<String>? = nil,
        neutronExtensions: Set<String> = []
    ) throws -> String {
        let rules = generate(readOnly: readOnly, services: services, resources: resources, neutronExtensions: neutronExtensions)
        let encoded = try JSONEncoder().encode(rules)
        guard let obj = try? JSONSerialization.jsonObject(with: encoded) else {
            throw AccessRuleError.encoding
        }
        let doc = ["rules": obj]
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .prettyPrinted])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Map a rule path to a coarse resource name (for `--resources` filtering).
    /// Returns nil for paths that don't map to a filterable resource.
    static func resourceForPath(_ path: String) -> String? {
        let first = path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
        switch first {
        case "servers", "servers/detail": return "server"
        case "flavors": return "flavor"
        case "os-keypairs": return "keypair"
        case "os-server-groups": return "server_group"
        case "os-availability-zone", "os-hypervisors", "os-services", "os-quota-sets": return nil
        case "networks": return "network"
        case "subnets": return "subnet"
        case "ports": return "port"
        case "routers": return "router"
        case "floatingips": return "floatingip"
        case "security-groups": return "security_group"
        case "security-group-rules": return "security_group_rule"
        case "address-groups": return "address_group"
        case "quotas": return nil
        case "volumes": return "volume"
        case "projects", "users", "groups", "roles", "domains", "services", "endpoints", "regions": return first
        case "images": return "image"
        default: return nil
        }
    }

    static func serviceFor(resource: String?) -> String? {
        switch resource {
        case "server", "flavor", "keypair", "server_group": return "compute"
        case "network", "subnet", "port", "router", "floatingip", "security_group", "security_group_rule", "address_group": return "network"
        case "volume": return "blockStorage"
        case "project", "user", "group", "role", "domain": return "identity"
        case "image": return "image"
        default: return nil
        }
    }
}

public enum AccessRuleError: Error { case encoding }
