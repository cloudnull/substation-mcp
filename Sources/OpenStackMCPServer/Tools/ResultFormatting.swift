import Foundation
import OpenStackClient

/// The result shape for list operations (spec §8.3).
public struct ListResult: Codable, Sendable {
    public let resource: String
    public let region: String
    public let count: Int
    public let items: [[String: JSONValue]]
    public let nextMarker: String?

    public init(resource: String, region: String, count: Int, items: [[String: JSONValue]], nextMarker: String? = nil) {
        self.resource = resource
        self.region = region
        self.count = count
        self.items = items
        self.nextMarker = nextMarker
    }
}

/// The result shape for mutation operations (spec §8.3).
public struct MutationResult: Codable, Sendable {
    public let resource: [String: JSONValue]
    public let requestID: String?
    /// Contextual next-step hints for the calling LLM harness. Only present
    /// when the resource type + action have known follow-up steps; omitted
    /// entirely otherwise so the field never appears as an empty array.
    public let nextSteps: [String]?

    public init(resource: [String: JSONValue], requestID: String? = nil, nextSteps: [String]? = nil) {
        self.resource = resource
        self.requestID = requestID
        self.nextSteps = nextSteps
    }
}

/// Project a raw resource JSON object to the named top-level fields.
/// Fields not present in the raw object are silently skipped.
public func project(_ raw: [String: JSONValue], _ fields: [String]) -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for field in fields {
        if let value = raw[field] {
            result[field] = value
        }
    }
    return result
}

/// Validate list filters against the descriptor's known filter set.
/// Throws if an unknown filter is present, listing the known ones (spec §8.2).
public func checkFilters(descriptor: ResourceDescriptor, filters: [String: String]) throws {
    let unknown = Set(filters.keys).subtracting(descriptor.listFilters)
    guard unknown.isEmpty else {
        let known = descriptor.listFilters.sorted().joined(separator: ", ")
        let unknownStr = unknown.sorted().joined(separator: ", ")
        throw OpenStackError(
            service: descriptor.service.rawValue,
            status: 400,
            code: "invalidFilter",
            message: "Unknown filter(s) for \(descriptor.name): \(unknownStr). Known filters: \(known)"
        )
    }
}

/// Build a one-paragraph error message (spec §8.3): what failed, HTTP status,
/// OpenStack message, request ID, and hint. Secrets and tokens are redacted.
public func errorParagraph(_ err: OpenStackError, what: String) -> String {
    var parts: [String] = []
    parts.append("\(what) failed")
    parts.append("HTTP \(err.status) from \(err.service)")
    if let code = err.code, !code.isEmpty {
        parts.append("code: \(code)")
    }
    let redactedMessage = redact(err.message)
    parts.append(redactedMessage)
    if let requestID = err.requestID, !requestID.isEmpty {
        parts.append("request ID: \(requestID)")
    }
    var hint = err.hint
    if hint == nil || hint?.isEmpty == true {
        hint = migrationHint(err)
    }
    if let hint, !hint.isEmpty {
        parts.append("Hint: \(hint)")
    }
    return parts.joined(separator: ", ")
}

/// Next-action hints for the classic Nova migration/evacuation faults
/// (message substrings validated live on IAD3, 2026-10-18). Turns the three
/// failure modes an evacuating admin actually hits into the right follow-up
/// call instead of a raw Nova fault.
func migrationHint(_ err: OpenStackError) -> String? {
    guard err.service == "compute" else { return nil }
    let m = err.message.lowercased()
    if m.contains("no such action") {
        return "The cloud's Nova rejects this action key. live_migrate sends `os-migrateLive`, cold migrate sends `migrate`, evacuate sends `evacuate` — retry the same os_action; if it persists the cloud pins a microversion without this extension."
    }
    if m.contains("policy doesn't allow") || m.contains("policynotauthorized") {
        return "Nova policy blocks this action for the current role (e.g. os_compute_api:os-migrate-server:* / os-evacuate need the cloud admin role). Re-login with an admin-scoped credential; the MCP role gate (policy.write_roles) is separate from Nova policy."
    }
    if m.contains("no valid host was found") {
        return "No host can satisfy the request: for a local/ephemeral-disk instance the target must accept block migration — pass params {block_migration: true, disk_over_commit: false}; check capacity with os_list(hypervisor) (local_gb vs local_gb_used) or os_action(placement, candidates) on clouds that expose placement."
    }
    if m.contains("cannot migrate instance") && m.contains("block migration") || m.contains("block migration") && m.contains("not supported") {
        return "The instance has local/ephemeral disks but the call didn't request block migration: use os_action(server, \"migrate\", params: {block_migration: true, disk_over_commit: false}) for a cold block migration (live block migration additionally requires the same flavor and CPU flags on both hosts)."
    }
    if m.contains("source and destination cannot be the same") {
        return "The host param names the instance's current host — pick a different target or omit host and let the scheduler choose."
    }
    if m.contains("instance is pinned") || m.contains("cpu pinning") {
        return "CPU-pinned instances can only live-migrate to a host with identical CPU topology; cold migrate (migrate) instead, or target an identical host model."
    }
    if (m.contains("cannot resize") && m.contains("task")) || m.contains("instance is busy") || m.contains("task_state") {
        return "Another task is in flight on this instance — os_wait(server, id, until: [\"settled\"]) first (settled = status ACTIVE with task_state null), then retry."
    }
    return nil
}

/// Redact known secret/token substrings from an error message.
/// Replaces any occurrence of "secret", "password", "token" (case-insensitive)
/// followed by `=` and a value, with `[REDACTED]`.
/// Also redacts any string that looks like a Keystone token ID
/// (a long alphanumeric string after "X-Auth-Token" or "token=").
public func redact(_ message: String) -> String {
    var result = message

    // Redact "secret=..." / "password=..." / "token=..." patterns
    for keyword in ["secret", "password", "token"] {
        let pattern = "(?i)(\(keyword)\\s*[:=]\\s*)(\\S+)"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsRange = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: nsRange, withTemplate: "$1[REDACTED]")
        }
    }

    // Redact long alphanumeric strings that look like token IDs
    // (32+ chars of alphanumerics and hyphens, typical Keystone token format)
    let tokenPattern = "\\b[a-zA-Z0-9]{32,}-[a-zA-Z0-9-]{16,}\\b"
    if let regex = try? NSRegularExpression(pattern: tokenPattern) {
        let nsRange = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: nsRange, withTemplate: "[REDACTED]")
    }

    return result
}
