import Foundation

/// Heat (orchestration) resource entries. 1 resource per spec (phase 2):
/// `stack` (pollable — status lifecycle CREATE_IN_PROGRESS ->
/// CREATE_COMPLETE). Stack outputs are exposed as the `get_outputs` action.
enum OrchestrationEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "stack",
            service: .orchestration,
            verbs: [.list, .get, .create, .delete],
            actions: [
                ActionSpec(name: "get_outputs", params: [])
            ],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Stack name"),
                    "template": .init(type: "string", description: "Template body (YAML/JSON)"),
                    "parameters": .init(type: "object", description: "Template parameters (key -> value)"),
                    "description": .init(type: "string", description: "Stack description"),
                ],
                required: ["name", "template"]
            ),
            updateSchema: nil,
            listFilters: ["name", "status"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["CREATE_COMPLETE", "UPDATE_COMPLETE", "DELETE_COMPLETE", "ROLLBACK_COMPLETE"],
            defaultListFields: ["id", "name", "status", "creation_time", "updated_at"]
        ),
    ]
}
