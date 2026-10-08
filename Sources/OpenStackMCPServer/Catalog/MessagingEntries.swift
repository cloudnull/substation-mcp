import Foundation

/// ZaQar (messaging) resource entries — phase 2, IAD3 gap-fill.
/// Resource: `queue` (queues are addressed by name; list is read-only,
/// create is implicit on first use).
enum MessagingEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "queue",
            service: .messaging,
            verbs: [.list, .get],
            actions: [],
            links: [],
            listFilters: ["name"],
            idField: "name",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["name", "messages_count", "oldest_message_timestamp", "created_at"]
        ),
    ]
}
