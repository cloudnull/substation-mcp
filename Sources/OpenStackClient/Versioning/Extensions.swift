import Foundation

/// Nova features and their minimum microversion requirements (spec §10.1).
public enum NovaFeature: String, Sendable, CaseIterable {
    case deleteOnTermination
    case hostname
    case pinnedAvailabilityZone
    case schedulerHintsEcho
    case asyncVolumeAttach

    /// The minimum microversion at which this feature is available.
    public func minMicroversion() -> Microversion {
        switch self {
        case .deleteOnTermination: Microversion(major: 2, minor: 79)
        case .hostname: Microversion(major: 2, minor: 90)
        case .pinnedAvailabilityZone: Microversion(major: 2, minor: 96)
        case .schedulerHintsEcho: Microversion(major: 2, minor: 100)
        case .asyncVolumeAttach: Microversion(major: 2, minor: 101)
        }
    }

    /// Whether this feature is available in the given negotiated microversion.
    public func available(in negotiated: Microversion) -> Bool {
        negotiated >= minMicroversion()
    }
}

/// Neutron extension aliases tracked for capability detection.
public struct NeutronExtensions: Sendable, Equatable {
    public let aliases: Set<String>

    public init(aliases: Set<String>) {
        self.aliases = aliases
    }

    public func has(_ alias: String) -> Bool {
        aliases.contains(alias)
    }
}
