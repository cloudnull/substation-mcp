import Foundation
import MCP
import OpenStackClient

/// MCP resource surface (spec §9): expose the catalog as static resources and
/// live OpenStack state as lazily-resolved resources, so a client can read
/// state without a tool call.
///
/// URIs:
/// - `openstack://catalog` — the full catalog index (static JSON).
/// - `openstack://catalog/{resource}` — one descriptor (static JSON).
/// - `openstack://{cloud}/{region}/{resource}/{id}` — current JSON of one
///   resource. Listed lazily: `resources/list` returns only the catalog URIs
///   plus the URI *template*; `resources/read` resolves it live via the
///   client. Subscriptions are not supported in phase 1.
public struct MCPResources: Sendable {
    let registry: ToolRegistry

    public init(registry: ToolRegistry) {
        self.registry = registry
    }

    // MARK: - List

    public func list() -> [Resource] {
        let catalog = registry.catalog
        var resources: [Resource] = [
            Resource(
                name: "catalog",
                uri: "openstack://catalog",
                title: "OpenStack resource catalog",
                description: "Index of every OpenStack resource this server can manage, with its verbs, actions, and links.",
                mimeType: "application/json"
            )
        ]
        for name in catalog.names.sorted() {
            resources.append(
                Resource(
                    name: "catalog/\(name)",
                    uri: "openstack://catalog/\(name)",
                    title: "Catalog entry: \(name)",
                    description: "Schema, verbs, actions, links, and terminal states for the \(name) resource.",
                    mimeType: "application/json"
                )
            )
        }
        resources.append(
            Resource(
                name: "resource template",
                uri: "openstack://\(registry.identity.cloudName)/\(registry.defaultRegion)/{resource}/{id}",
                title: "Live OpenStack resource",
                description: "Read the current JSON of one OpenStack resource by URI. Resolve live via resources/read.",
                mimeType: "application/json"
            )
        )
        return resources
    }

    // MARK: - Read

    public func read(_ uri: String) async -> [Resource.Content] {
        let parts = uri.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // openstack://catalog  -> ["openstack:", "", "catalog"]
        // openstack://catalog/server -> ["openstack:", "", "catalog", "server"]
        // openstack://fake/RegionOne/server/srv-0001 -> ["openstack:", "", "fake", "RegionOne", "server", "srv-0001"]
        guard parts.count >= 3 else {
            return [errorContent(uri, "Malformed resource URI: \(uri)")]
        }
        guard parts[0] == "openstack:" else {
            return [errorContent(uri, "Unsupported scheme in \(uri): expected openstack://")]
        }
        guard parts[2] == "catalog" else {
            return await readLive(uri, parts: parts)
        }

        if parts.count == 3 {
            return [catalogIndexContent]
        }
        if parts.count == 4 {
            let resourceName = parts[3]
            guard let d = registry.catalog.descriptor(resourceName) else {
                return [errorContent(uri, "Unknown resource: \(resourceName). Valid: \(registry.catalog.names.sorted().joined(separator: ", "))")]
            }
            return [.text(descriptorJSON(d), uri: uri, mimeType: "application/json")]
        }
        return [errorContent(uri, "Malformed catalog URI: \(uri)")]
    }

    private func readLive(_ uri: String, parts: [String]) async -> [Resource.Content] {
        // openstack://{cloud}/{region}/{resource}/{id}
        guard parts.count == 6 else {
            return [errorContent(uri, "Malformed resource URI: \(uri). Expected openstack://{cloud}/{region}/{resource}/{id}")]
        }
        let (cloud, region, resourceName, id) = (parts[2], parts[3], parts[4], parts[5])
        guard cloud == registry.identity.cloudName else {
            return [errorContent(uri, "Unknown cloud: \(cloud). This session is bound to cloud \(registry.identity.cloudName).")]
        }
        guard let d = registry.catalog.descriptor(resourceName) else {
            return [errorContent(uri, "Unknown resource: \(resourceName). Valid: \(registry.catalog.names.sorted().joined(separator: ", "))")]
        }

        do {
            let resolver = NameResolver(catalog: registry.catalog, client: registry.client)
            let (_, raw) = try await resolver.resolve(registry.identity.vt, descriptor: d, idOrName: id, region: region)
            let body: [String: JSONValue] = [
                "resource": .string(d.name),
                "region": .string(region),
                "id": .string(id),
                "data": .object(raw),
            ]
            return [contentJSON(body, uri: uri)]
        } catch {
            return [errorContent(uri, resourceErrorText(error, resource: d.name, id: id))]
        }
    }

    // MARK: - JSON helpers

    private var catalogIndexContent: Resource.Content {
        let names = registry.catalog.names.sorted()
        let body: [String: JSONValue] = [
            "resources": .array(names.map { .string($0) }),
            "count": .integer(names.count),
        ]
        return contentJSON(body, uri: "openstack://catalog")
    }

    private func contentJSON(_ body: [String: JSONValue], uri: String) -> Resource.Content {
        let value = registry.toValue(.object(body))
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? value.description
        return .text(text, uri: uri, mimeType: "application/json")
    }

    private func errorContent(_ uri: String, _ message: String) -> Resource.Content {
        .text(message, uri: uri, mimeType: "text/plain")
    }

    private func resourceErrorText(_ error: Error, resource: String, id: String) -> String {
        if let osErr = error as? OpenStackError {
            return "\(resource) '\(id)' not found: \(osErr.message)"
        }
        if let ambig = error as? AmbiguousNameError {
            return ambig.description
        }
        return "\(resource) '\(id)' could not be read: \(error.localizedDescription)"
    }

    private func descriptorJSON(_ d: ResourceDescriptor) -> String {
        let body: [String: JSONValue] = [
            "resource": .string(d.name),
            "service": .string(d.service.rawValue),
            "verbs": .array(d.verbs.sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) }),
            "id_field": .string(d.idField),
            "name_field": .string(d.nameField ?? ""),
            "terminal_states": .array(d.terminalStates.map { .string($0) }),
            "actions": .array(d.actions.map { .object(["name": .string($0.name)]) }),
            "links": .array(d.links.map { .object(["kind": .string($0.kind)]) }),
        ]
        return contentJSON(body, uri: "").text ?? ""
    }
}
