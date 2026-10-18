import Foundation

/// Heat-CFN (cloudformation) resource entries — phase 2, IAD3 gap-fill.
///
/// The CFN API is AWS-query style over the heat-api-cfn endpoint. Auth is
/// Keystone-token-as-AWSAccessKeyId (signature check skipped for Keystone
/// tokens), which requires the token to carry the `heat_stack_user` role —
/// Rackspace grants it project-wide; other clouds may return 403. Verified
/// live on IAD3 (2026-10-18).
///
/// Stack identity: heat-cfn's `StackName` is the unique key (DescribeStacks /
/// UpdateStack / DeleteStack all take StackName); `StackId` is the ARN/uuid
/// returned by create.
enum CloudFormationEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "cfn_stack",
            service: .cloudformation,
            verbs: [.list, .get, .create, .update, .delete],
            actions: [
                ActionSpec(name: "validate_template", params: [
                    ParamSpec(name: "template_body", required: true, description: "Template (JSON/YAML) to validate; returns its parameter keys")
                ]),
            ],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Stack name (unique key for later get/update/delete)"),
                    "template_body": .init(type: "string", description: "Template body (JSON or YAML string)"),
                    "template_url": .init(type: "string", description: "Template URL (alternative to template_body)"),
                    "parameters": .init(type: "object", description: "Stack parameters (key -> value)"),
                    "tags": .init(type: "object", description: "Stack tags (key -> value)"),
                    "disable_rollback": .init(type: "boolean", description: "Disable rollback on failure")
                ],
                required: ["name"]
            ),
            updateSchema: .init(
                type: "object",
                properties: [
                    "template_body": .init(type: "string", description: "New template body"),
                    "parameters": .init(type: "object", description: "Updated parameters (key -> value)")
                ]
            ),
            listFilters: [],
            idField: "StackId",
            nameField: "StackName",
            statusField: "StackStatus",
            terminalStates: ["CREATE_COMPLETE", "CREATE_FAILED", "UPDATE_COMPLETE", "UPDATE_FAILED", "ROLLBACK_COMPLETE", "ROLLBACK_FAILED", "DELETE_COMPLETE", "DELETE_FAILED"],
            defaultListFields: ["StackId", "StackName", "StackStatus", "CreationTime"],
            phase1Note: "heat-cfn authenticates with AWS query signing (AWSAccessKeyId/Signature), not Keystone bearer tokens; Rackspace maps the caller via the signing credential. On IAD3 (2026-10-18) every app-credential shape (token-as-key, SigV2-signed) is rejected with AccessDenied — the surface needs cloud-specific AWS keys. Use the native Heat surface (resource `stack`) for Keystone-authenticated stacks; they are the same underlying stacks, ids are not interchangeable between the two surfaces."
        ),
    ]
}
