import Foundation
import Yams

/// A single cloud entry from clouds.yaml (or secure.yaml override).
public struct CloudEntry: Sendable, Equatable {
    public let name: String
    public let authURL: URL?
    public let regionName: String?
    public let interface: String
    public var cacert: String?
    public var verify: Bool
    public let appCredID: String?
    public let appCredSecret: String?

    public init(
        name: String,
        authURL: URL? = nil,
        regionName: String? = nil,
        interface: String = "public",
        cacert: String? = nil,
        verify: Bool = true,
        appCredID: String? = nil,
        appCredSecret: String? = nil
    ) {
        self.name = name
        self.authURL = authURL
        self.regionName = regionName
        self.interface = interface
        self.cacert = cacert
        self.verify = verify
        self.appCredID = appCredID
        self.appCredSecret = appCredSecret
    }
}

/// Error for strict clouds.yaml loading.
public struct CloudConfigError: Error, Sendable, CustomStringConvertible {
    public let name: String
    public let reason: String

    public var description: String {
        "clouds.yaml entry '\(name)': \(reason)"
    }

    public static func malformedEntry(name: String, reason: String) -> CloudConfigError {
        CloudConfigError(name: name, reason: reason)
    }
}

/// Tolerant clouds.yaml / secure.yaml loader.
public struct CloudConfig: Sendable {
    public let clouds: [CloudEntry]

    public init(clouds: [CloudEntry]) {
        self.clouds = clouds
    }

    public var defaultCloud: CloudEntry? { clouds.first }

    public func cloud(named name: String) -> CloudEntry? {
        clouds.first { $0.name == name }
    }

    // MARK: - Tolerant load

    public static func load(file: URL?) -> CloudConfig {
        guard let url = resolvedFileURL(explicit: file) else {
            return CloudConfig(clouds: [])
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return CloudConfig(clouds: [])
        }
        let secure = secureSiblingURL(for: url)
        guard let entries = parse(text: text, secureSibling: secure, strict: false) else {
            return CloudConfig(clouds: [])
        }
        return CloudConfig(clouds: entries)
    }

    // MARK: - Strict load

    public static func loadStrict(file: URL) throws -> CloudConfig {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw CloudConfigError.malformedEntry(name: "<file>", reason: "cannot read \(file.path)")
        }
        let secure = secureSiblingURL(for: file)
        guard let entries = parse(text: text, secureSibling: secure, strict: true) else {
            throw CloudConfigError.malformedEntry(name: "<parse>", reason: "YAML decode failed")
        }
        return CloudConfig(clouds: entries)
    }

    // MARK: - Search order

    private static func resolvedFileURL(explicit: URL?) -> URL? {
        if let explicit { return explicit }
        var candidates: [URL] = [
            URL(fileURLWithPath: "./clouds.yaml"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/openstack/clouds.yaml"),
            URL(fileURLWithPath: "/etc/openstack/clouds.yaml"),
        ]
        if let envPath = ProcessInfo.processInfo.environment["OS_CLIENT_CONFIG_FILE"] {
            candidates.insert(URL(fileURLWithPath: envPath), at: 0)
        }
        for c in candidates where FileManager.default.fileExists(atPath: c.path) {
            return c
        }
        return nil
    }

    private static func secureSiblingURL(for url: URL) -> URL? {
        let sibling = url.deletingLastPathComponent().appendingPathComponent("secure.yaml")
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
    }

    // MARK: - Parsing

    /// Returns entries or nil on unrecoverable error.
    private static func parse(text: String, secureSibling: URL?, strict: Bool) -> [CloudEntry]? {
        // Yams.load returns a nested [String: Any] tree.
        guard let doc: Any = try? Yams.load(yaml: text),
              let root = doc as? [String: Any],
              let cloudsRaw = root["clouds"] as? [String: Any] else {
            return strict ? nil : []
        }

        var entries: [CloudEntry] = []
        let order = rawKeyOrder(text: text, under: "clouds")
        let names = order.isEmpty ? cloudsRaw.keys.sorted() : order

        for name in names {
            guard let valueRaw = cloudsRaw[name] else { continue }

            guard let entry = makeEntry(name: name, raw: valueRaw) else {
                if strict { return nil }
                print("clouds.yaml: skipping entry '\(name)': auth block is not a valid map")
                continue
            }
            entries.append(entry)
        }

        // Inline secure: overrides (cacert + verify only).
        if let secureRaw = root["secure"] as? [String: Any] {
            applySecure(secureRaw: secureRaw, to: &entries)
        }

        // Sibling secure.yaml overrides.
        if let secureURL = secureSibling,
           let secureText = try? String(contentsOf: secureURL, encoding: .utf8),
           let secureDoc: Any = try? Yams.load(yaml: secureText),
           let secureRoot = secureDoc as? [String: Any],
           let secureMapping = secureRoot["secure"] as? [String: Any]
            ?? secureRoot["clouds"] as? [String: Any] {
            applySecure(secureRaw: secureMapping, to: &entries)
        }

        return entries
    }

    private static func makeEntry(name: String, raw: Any) -> CloudEntry? {
        guard let dict = raw as? [String: Any] else {
            // The entry value is not a mapping (e.g. a bare string) — malformed.
            return nil
        }

        let regionName = dict["region_name"] as? String ?? dict["region"] as? String
        let interface = dict["interface"] as? String ?? "public"
        let cacert = dict["cacert"] as? String
        let verify: Bool
        if let v = dict["verify"] as? Bool {
            verify = v
        } else if let v = dict["verify"] as? String {
            verify = v.lowercased() == "true"
        } else {
            verify = true
        }

        let authDict = dict["auth"] as? [String: Any]
        let authURLStr = authDict?["auth_url"] as? String
        let appCredID = authDict?["application_credential_id"] as? String
        let appCredSecret = authDict?["application_credential_secret"] as? String

        // If auth is present but not a dict, the entry is malformed.
        if dict["auth"] != nil && authDict == nil {
            return nil
        }

        let authURL = authURLStr.flatMap { URL(string: $0) }
        if authURLStr != nil && authURL == nil {
            return nil
        }

        return CloudEntry(
            name: name,
            authURL: authURL,
            regionName: regionName,
            interface: interface,
            cacert: cacert,
            verify: verify,
            appCredID: appCredID,
            appCredSecret: appCredSecret
        )
    }

    private static func applySecure(secureRaw: [String: Any], to entries: inout [CloudEntry]) {
        for i in entries.indices {
            guard let sv = secureRaw[entries[i].name] as? [String: Any] else { continue }
            if let c = sv["cacert"] as? String { entries[i].cacert = c }
            if let v = sv["verify"] as? Bool { entries[i].verify = v }
            else if let v = sv["verify"] as? String { entries[i].verify = v.lowercased() == "true" }
        }
    }

    /// Re-scan raw YAML to recover key order under a top-level `clouds:` key.
    private static func rawKeyOrder(text: String, under key: String) -> [String] {
        var order: [String] = []
        var inClouds = false
        var cloudsIndent = -1
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.replacingOccurrences(of: "\t", with: "  ")
            let indent = trimmed.prefix { $0 == " " }.count
            let content = trimmed.trimmingCharacters(in: .whitespaces)
            if content.isEmpty || content.hasPrefix("#") { continue }
            if content.hasPrefix("\(key):") {
                inClouds = true
                cloudsIndent = indent
                continue
            }
            guard inClouds else { continue }
            if indent <= cloudsIndent && content.contains(":") {
                inClouds = false
                continue
            }
            if indent == cloudsIndent + 2,
               let colonIdx = content.firstIndex(of: ":") {
                let name = content[..<colonIdx].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !name.hasPrefix("#") {
                    order.append(name)
                }
            }
        }
        return order
    }
}
