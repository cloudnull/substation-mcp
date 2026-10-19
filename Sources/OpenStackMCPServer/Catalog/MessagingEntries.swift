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
            defaultListFields: ["name", "messages_count", "oldest_message_timestamp", "created_at"],
            phase1Note: "Live-validated on IAD3 (2026-10-19): the catalog advertises zaqar at the host root and `/` serves the v2 version doc, but every authenticated request 503s — the failure is in ZaQar's Keystone token-validation hop, not the queue API (no token → 401, any token → 503 'The Keystone service is temporarily unavailable', stable across v1/v2 and retries; DFW3 ZaQar is up but rejects the IAD3-scoped token with 401 as expected cross-region). The client is wired and fake-tested; retry when the upstream heals — no code change needed."
        ),
    ]
}
