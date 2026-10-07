import Foundation
import OpenStackClient

/// Deployment-level policy that controls which resources, verbs, and actions
/// are available. Applied to the catalog before tools are registered.
public struct Policy: Sendable {
    public var readOnly: Bool
    public var denyResources: Set<String>
    public var denyVerbs: [String: Set<Verb>]
    public var denyActions: [String: Set<String>]
    public var maxListLimit: Int
    public var maxCallsPerMinute: Int

    public init(
        readOnly: Bool = false,
        denyResources: Set<String> = Policy.defaultDenyResources,
        denyVerbs: [String: Set<Verb>] = [:],
        denyActions: [String: Set<String>] = [:],
        maxListLimit: Int = 200,
        maxCallsPerMinute: Int = 1024
    ) {
        self.readOnly = readOnly
        self.denyResources = denyResources
        self.denyVerbs = denyVerbs
        self.denyActions = denyActions
        self.maxListLimit = maxListLimit
        self.maxCallsPerMinute = maxCallsPerMinute
    }

    /// The six identity-admin resource names denied by default (spec §12).
    public static let defaultDenyResources: Set<String> = [
        "project", "user", "group", "role", "role_assignment", "domain"
    ]

    /// The default policy: identity-admin resources denied, maxListLimit 200,
    /// maxCallsPerMinute 1024.
    public var defaultPolicy: Policy {
        Policy(
            readOnly: readOnly,
            denyResources: Policy.defaultDenyResources,
            denyVerbs: denyVerbs,
            denyActions: denyActions,
            maxListLimit: maxListLimit,
            maxCallsPerMinute: maxCallsPerMinute
        )
    }

    /// Apply denials to a catalog, returning a filtered copy.
    ///
    /// - Denied resources are removed entirely.
    /// - Denied verbs are removed from the descriptor's verb set.
    /// - Denied actions are removed from the descriptor's action list.
    public func effective(_ catalog: ResourceCatalog) -> ResourceCatalog {
        var descriptors: [ResourceDescriptor] = []
        for d in catalog.resources {
            // Remove denied resources entirely
            if denyResources.contains(d.name) {
                continue
            }

            // Remove denied verbs
            var verbs = d.verbs
            if let deniedVerbs = denyVerbs[d.name] {
                verbs.subtract(deniedVerbs)
            }

            // Remove denied actions
            var actions = d.actions
            if let deniedActions = denyActions[d.name] {
                actions = actions.filter { !deniedActions.contains($0.name) }
            }

            descriptors.append(ResourceDescriptor(
                name: d.name,
                service: d.service,
                verbs: verbs,
                actions: actions,
                links: d.links,
                createSchema: d.createSchema,
                updateSchema: d.updateSchema,
                listFilters: d.listFilters,
                idField: d.idField,
                nameField: d.nameField,
                statusField: d.statusField,
                terminalStates: d.terminalStates,
                defaultListFields: d.defaultListFields,
                destructiveHints: d.destructiveHints,
                phase1Note: d.phase1Note,
                dispatch: d.dispatch
            ))
        }
        return ResourceCatalog(resources: descriptors)
    }

    /// The set of tool names enabled for a read-only session.
    public func toolsEnabled(readOnlyList: [String] = [
        "os_list", "os_get", "os_describe", "os_topology",
        "os_find", "os_whoami", "os_quota", "os_clouds", "os_wait",
        "os_task_submit", "os_task_status", "os_task_cancel"
    ]) -> Set<String> {
        Set(readOnlyList)
    }
}
