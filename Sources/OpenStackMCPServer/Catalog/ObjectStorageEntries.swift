import Foundation

/// Swift (object storage) resource entries. 2 resources per spec (phase 2):
/// `container` and `object`.
enum ObjectStorageEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "container",
            service: .objectStorage,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Container name"),
                    "quota_bytes": .init(type: "integer", description: "Container quota in bytes"),
                    "metadata": .init(type: "object", description: "Container metadata (X-Container-Meta-*)")
                ],
                required: ["name"]
            ),
            updateSchema: nil,
            listFilters: ["name", "prefix"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "count", "bytes"]
        ),
        ResourceDescriptor(
            name: "object",
            service: .objectStorage,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "container": .init(type: "string", description: "Container to store the object in"),
                    "name": .init(type: "string", description: "Object name"),
                    "content": .init(type: "string", description: "Object content (base64 or text)"),
                    "content_type": .init(type: "string", description: "MIME type"),
                    "metadata": .init(type: "object", description: "Object metadata (X-Object-Meta-*)")
                ],
                required: ["container", "name", "content"]
            ),
            updateSchema: nil,
            listFilters: ["name", "prefix", "container"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "size", "content_type"]
        ),
    ]
}
