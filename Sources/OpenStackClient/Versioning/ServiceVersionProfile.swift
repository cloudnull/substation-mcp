import Foundation

/// Describes how a service negotiates its API version: the version document to
/// fetch, whether it uses a microversion header, the client's max supported
/// microversion, the floor below which we refuse to operate, and the header
/// name + value format to send once negotiated.
///
/// - Services with `hasMicroversion == true` (nova, cinder) send the negotiated
///   microversion on every request via `headerName`/`headerValue`.
/// - Services without microversions (glance, neutron, octavia, barbican, ...)
///   negotiate the **version unit** only (the `/v2`, `/v3` path root, handled by
///   endpoint resolution's `serviceRoot`); no header is sent.
public struct ServiceVersionProfile: Sendable {
    public let serviceType: String
    /// The version document path to GET (relative to the service endpoint root),
    /// e.g. `""` for the root.
    public let versionDocPath: String
    /// Whether this service uses a microversion header.
    public let hasMicroversion: Bool
    /// The header name for the microversion (e.g. `X-OpenStack-Nova-API-Version`,
    /// or `OpenStack-API-Version` for cinder where the value is `volume 3.x`).
    public let headerName: String
    /// The client's max supported microversion (what our models decode).
    public let clientMax: Microversion
    /// The floor below which we refuse to operate (nil = no floor).
    public let floor: Microversion?
    /// How to format the header value from the negotiated microversion. For
    /// cinder this is `volume 3.x`; for nova it's just `3.x`-style `major.minor`.
    public let headerValue: @Sendable (Microversion) -> String

    public init(
        serviceType: String,
        versionDocPath: String = "",
        hasMicroversion: Bool = false,
        headerName: String = "",
        clientMax: Microversion,
        floor: Microversion? = nil,
        headerValue: @escaping @Sendable (Microversion) -> String = { $0.stringValue }
    ) {
        self.serviceType = serviceType
        self.versionDocPath = versionDocPath
        self.hasMicroversion = hasMicroversion
        self.headerName = headerName
        self.clientMax = clientMax
        self.floor = floor
        self.headerValue = headerValue
    }
}

extension ServiceVersionProfile {
    /// Per-service profiles for the services that matter. Nova and cinder use
    /// microversion headers; the rest negotiate the version unit only.
    public static func profile(for serviceType: String) -> ServiceVersionProfile? {
        switch serviceType {
        case "compute":
            // Nova: max 2.104 (client decodes up to 2.104); floor 2.79
            // (delete_on_termination). Header: X-OpenStack-Nova-API-Version.
            return ServiceVersionProfile(
                serviceType: "compute",
                hasMicroversion: true,
                headerName: "X-OpenStack-Nova-API-Version",
                clientMax: Microversion(major: 2, minor: 104),
                floor: Microversion(major: 2, minor: 79)
            )
        case "volumev3":
            // Cinder: max 3.x; header OpenStack-API-Version: volume 3.x.
            // clientMax matches BlockStorageRegion.clientMax ("3.70").
            return ServiceVersionProfile(
                serviceType: "volumev3",
                hasMicroversion: true,
                headerName: "OpenStack-API-Version",
                clientMax: Microversion(major: 3, minor: 70),
                floor: nil,
                headerValue: { "volume \($0.major).\($0.minor)" }
            )
        case "image", "network", "load-balancer", "key-manager", "container-infra",
             "orchestration", "object-store", "dns", "sharev2":
            // Version-unit only; no microversion header.
            return ServiceVersionProfile(serviceType: serviceType, clientMax: Microversion(major: 1, minor: 0))
        default:
            return nil
        }
    }
}
