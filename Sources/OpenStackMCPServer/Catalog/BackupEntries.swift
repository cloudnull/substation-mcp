import Foundation

/// Freezer (backup) resource entries — phase 2, IAD3 gap-fill.
/// Resources: `backup` (freezer backup records, addressed by backup_id) and
/// `schedule` (recurring backup schedules).
enum BackupEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "backup",
            service: .backup,
            verbs: [.list, .get],
            actions: [],
            links: [],
            listFilters: ["status", "volume_id", "project_id"],
            idField: "id",
            nameField: nil,
            statusField: "status",
            terminalStates: [],
            defaultListFields: ["id", "project_id", "volume_id", "status", "size", "last_backup", "created_at"],
            phase1Note: "Freezer on IAD3 currently serves from a dfw3 dev endpoint (401 for IAD3 tokens); the client is wired for a corrected catalog endpoint."
        ),
        ResourceDescriptor(
            name: "schedule",
            service: .backup,
            verbs: [.list, .get],
            actions: [],
            links: [],
            listFilters: ["volume_id", "project_id"],
            idField: "id",
            nameField: nil,
            statusField: "status",
            terminalStates: [],
            defaultListFields: ["id", "volume_id", "project_id", "backup_interval_hours", "status"]
        ),
    ]
}
