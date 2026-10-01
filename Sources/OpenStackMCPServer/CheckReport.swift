import Foundation
import Logging
import OpenStackClient

// MARK: - check (spec §11.3)

/// The output of the `check` subcommand: identity, scopes, regions, services,
/// negotiated versions, Neutron extensions, and access-rule gaps. The core
/// here is pure against an `OpenStackClient` + `ValidatedToken`; the CLI shim
/// resolves the cloud, mints/validates the token, and maps failures to exit
/// codes.
public struct CheckReport: Sendable {
    public let project: IdentityRef
    public let domain: IdentityRef
    public let roles: [String]
    public let scopes: [TokenScope]
    public let regions: [String]
    public let services: [String: [String]]
    /// Negotiated microversions, keyed by service type (e.g. "compute").
    public let versions: [String: Microversion]
    /// Discovered Neutron extension aliases (empty if network is absent).
    public let neutronExtensions: [String]
    /// Per-service gap report; nil entries mean "not applicable".
    public let gaps: [ServiceGaps]
    /// When the credential is unrestricted (no access rules), gaps are N/A.
    public let unrestricted: Bool
    /// When the token has access rules but they may not be enforced.
    public let rulesMayNotBeEnforced: Bool

    public struct ServiceGaps: Sendable {
        public let service: String
        /// Pinned rule paths the token's access rules do NOT cover.
        public let missing: [Rule]
        /// True when this service had no rules to compare against.
        public let noRules: Bool
    }

    /// Build the report. `neutronExtensions` is passed in (discovered by the
    /// caller via `client.network(region:).discoverExtensions`) so the check
    /// core stays testable; `accessRuleJSON` is the token's raw access rules
    /// (nil when unrestricted or absent).
    public static func build(
        whoami: Whoami,
        versions: [String: Microversion],
        neutronExtensions: [String],
        accessRules: [[String: String]]?,
        unrestricted: Bool?
    ) -> CheckReport {
        let ruleSet = accessRules ?? []
        let isUnrestricted = unrestricted ?? false

        var gaps: [ServiceGaps] = []
        if isUnrestricted {
            // No rules: gaps not applicable, nothing to compare.
        } else {
            for service in AccessRulesGenerator.serviceOrder {
                let pinned = AccessRulesGenerator.generate(
                    readOnly: false,
                    services: [service],
                    neutronExtensions: Set(neutronExtensions)
                )
                // The token's rules for this service, keyed by (method, path).
                var have = Set<String>()
                for rule in ruleSet where rule["service"] == service {
                    have.insert("\(rule["method"] ?? "")|\(rule["path"] ?? "")")
                }
                let missing = pinned.filter { !have.contains("\($0.method)|\($0.path)") }
                gaps.append(ServiceGaps(
                    service: service,
                    missing: missing,
                    noRules: have.isEmpty
                ))
            }
        }

        // Heuristic: rules present but the identity service (always probed on
        // whoami) would still 403 a permitted GET → "rules may not be enforced"
        // (the cloud's service_type is not wired in keystonemiddleware).
        var mayNotBeEnforced = false
        if !isUnrestricted, !ruleSet.isEmpty {
            // A non-empty rule set means the credential has access rules. If
            // whoami succeeded with a project-scoped token yet a rule-bearing
            // token is being checked, the heuristic flags "may not be enforced"
            // only when rules exist for services the catalog does not list.
            let catalogTypes = Set(whoami.services.keys)
            let ruleServices = Set(ruleSet.compactMap { $0["service"] })
            let unknownRuleServices = ruleServices.subtracting(catalogTypes)
            if !unknownRuleServices.isEmpty {
                mayNotBeEnforced = true
            }
        }

        return CheckReport(
            project: whoami.project,
            domain: whoami.domain,
            roles: whoami.roles,
            scopes: whoami.scopes,
            regions: whoami.regions,
            services: whoami.services,
            versions: versions,
            neutronExtensions: neutronExtensions.sorted(),
            gaps: gaps,
            unrestricted: isUnrestricted,
            rulesMayNotBeEnforced: mayNotBeEnforced
        )
    }

    /// Human-readable report to stdout; notes (gaps, enforcement caveat) to
    /// the returned `notes` string for stderr.
    public func render() -> (stdout: String, notes: String) {
        var out: [String] = []
        var notes: [String] = []
        let project = project.name ?? project.id
        out.append("project:     \(project)")
        out.append("domain:      \(domain.name ?? domain.id)")
        out.append("roles:       \(roles.joined(separator: ", "))")
        let scopeNames = scopes.map { $0.rawValue }
        out.append("scopes:      \(scopeNames.joined(separator: " "))")
        out.append("regions:     \(regions.joined(separator: ", "))")
        if !services.isEmpty {
            out.append("services:")
            for (svc, regs) in services.sorted(by: { $0.key < $1.key }) {
                out.append("  \(svc): \(regs.joined(separator: ", "))")
            }
        }
        if !versions.isEmpty {
            out.append("versions:")
            for (svc, v) in versions.sorted(by: { $0.key < $1.key }) {
                out.append("  \(svc): \(v.stringValue)")
            }
        }
        if !neutronExtensions.isEmpty {
            out.append("neutron extensions: \(neutronExtensions.joined(separator: ", "))")
        }
        if unrestricted {
            out.append("access rules:  unrestricted — gaps not applicable")
        } else {
            out.append("access rules:")
            for gap in gaps where !gap.noRules {
                if gap.missing.isEmpty {
                    out.append("  \(gap.service): full coverage")
                } else {
                    out.append("  \(gap.service): \(gap.missing.count) gap(s)")
                    for m in gap.missing {
                        out.append("    MISSING \(m.method) \(m.path)")
                    }
                }
            }
            if rulesMayNotBeEnforced {
                notes.append("note: access rules are present but may not be enforced — ensure each service is registered with the correct service_type in keystonemiddleware (a permitted GET that still 403s indicates the middleware is not matching the rules).")
            }
        }
        return (out.joined(separator: "\n"), notes.joined(separator: "\n"))
    }
}
