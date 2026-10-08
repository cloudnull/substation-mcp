import Foundation

/// Heat-CFN (cloudformation) resource entries — phase 2, IAD3 gap-fill.
/// The CFN API authenticates with AWS SigV4 request signing, not Keystone
/// tokens, so no data-plane client exists. The resource is registered so it
/// shows up in the catalog and tools with an honest 501 by design.
enum CloudFormationEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "cfn_stack",
            service: .cloudformation,
            verbs: [.list, .get],
            actions: [],
            links: [],
            idField: "StackId",
            nameField: "StackName",
            statusField: "StackStatus",
            terminalStates: ["CREATE_COMPLETE", "UPDATE_COMPLETE", "DELETE_COMPLETE", "ROLLBACK_COMPLETE"],
            defaultListFields: ["StackId", "StackName", "StackStatus", "CreationTime"],
            phase1Note: "CloudFormation (heat-cfn) uses AWS SigV4 signing, not Keystone tokens; not resolvable in phase 1 (HTTP 501 by design). For Heat stacks see the `stack` resource."
        ),
    ]
}
