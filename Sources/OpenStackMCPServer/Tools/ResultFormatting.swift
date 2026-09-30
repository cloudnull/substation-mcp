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

    public init(resource: [String: JSONValue], requestID: String? = nil) {
        self.resource = resource
        self.requestID = requestID
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
    if let hint = err.hint, !hint.isEmpty {
        parts.append("Hint: \(hint)")
    }
    return parts.joined(separator: ", ")
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
