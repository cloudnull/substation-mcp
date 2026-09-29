import Foundation

/// API microversion (e.g. 2.79 for Nova). Numeric comparison, not lexicographic.
public struct Microversion: Comparable, Sendable, Hashable, Codable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else { return nil }
        self.major = major
        self.minor = minor
    }

    public var stringValue: String {
        "\(major).\(minor)"
    }

    public static func < (lhs: Microversion, rhs: Microversion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }
}
