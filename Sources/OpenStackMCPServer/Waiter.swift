import Foundation
import MCP
import OpenStackClient
import Logging

/// Polls a resource until it reaches a terminal state (or one of `until`),
/// a fault state (ERROR/killed), a deleted 404, or a timeout.
///
/// Backoff doubles from 1s to a 10s cap. When the MCP request carried a
/// progress token, intermediate statuses are reported via
/// `notifications/progress` (§8.9).
public struct Waiter: Sendable {
    public let client: OpenStackClient
    public let catalog: ResourceCatalog
    public let logger: Logger

    public init(client: OpenStackClient, catalog: ResourceCatalog, logger: Logger = Logger(label: "openstack-mcp-waiter")) {
        self.client = client
        self.catalog = catalog
        self.logger = logger
    }

    /// The states a wait can legitimately target: the descriptor's terminal
    /// states plus the fault states.
    private func validStates(_ descriptor: ResourceDescriptor) -> [String] {
        var states = Set(descriptor.terminalStates)
        states.insert("ERROR")
        states.insert("killed")
        return Array(states).sorted()
    }

    /// Wait for `resource`/`id` in `region`.
    /// - Parameters:
    ///   - vt: validated token
    ///   - resource: catalog resource name (e.g. "server")
    ///   - id: resource id
    ///   - region: region name
    ///   - until: optional list of acceptable final states; each must be a
    ///     known state (terminal or fault). Defaults to the terminal states.
    ///   - timeout: overall timeout (seconds)
    ///   - waitingForDelete: when true, a 404 counts as success (deleted: true)
    ///   - progressToken: when non-nil, intermediate statuses are reported
    ///     via `notifications/progress` to the connected MCP server
    ///   - server: the MCP server to notify (nil = no progress reporting)
    public func wait(
        _ vt: ValidatedToken,
        resource: String,
        id: String,
        region: String,
        until: [String]?,
        timeout: TimeInterval,
        waitingForDelete: Bool = false,
        progressToken: ProgressToken? = nil,
        server: MCP.Server? = nil
    ) async throws -> [String: JSONValue] {
        guard let descriptor = catalog.descriptor(resource) else {
            throw OpenStackError(
                service: "mcp", status: 400, code: "unknownResource",
                message: "Unknown resource: \(resource). Valid: \(catalog.names.sorted().joined(separator: ", "))"
            )
        }

        // Validate `until` against known states
        if let until, !until.isEmpty {
            let known = Set(validStates(descriptor))
            for state in until where !known.contains(state) {
                throw OpenStackError(
                    service: "mcp", status: 400, code: "invalidState",
                    message: "Unknown state: \(state). Valid states for \(resource): \(validStates(descriptor).joined(separator: ", "))"
                )
            }
        }

        // Reject resources with no status to poll *before* fetching anything,
        // so a bad (or not-yet-existing) id can't masquerade as "deleted".
        if !supportsWaiting(descriptor) {
            throw OpenStackError(service: "mcp", status: 501, code: "notPollable",
                message: "Waiting on \(resource) not supported: it has no status field to poll")
        }

        let targets: Set<String>
        if let until, !until.isEmpty {
            targets = Set(until)
        } else {
            targets = Set(descriptor.terminalStates)
        }
        let faultStates: Set<String> = ["ERROR", "killed"]

        var backoff: TimeInterval = 1.0
        let cap: TimeInterval = 10.0
        let start = Date()
        let timeoutDate = start.addingTimeInterval(timeout)
        var lastStatus: String?
        var polls = 0

        while Date() < timeoutDate {
            polls += 1
            let (status, exists): (String, Bool) = await fetchStatus(vt, descriptor: descriptor, id: id, region: region)

            if !exists {
                if waitingForDelete {
                    return [
                        "resource": .string(resource),
                        "id": .string(id),
                        "region": .string(region),
                        "deleted": .bool(true),
                        "status": .string("deleted"),
                        "elapsedSeconds": .float(elapsed(start)),
                        "polls": .integer(polls),
                    ]
                }
                // Resource vanished while waiting for a state: report it
                throw OpenStackError(
                    service: "mcp", status: 404, code: "itemNotFound",
                    message: "Resource \(resource) \(id) no longer exists (last status: \(lastStatus ?? "unknown"))"
                )
            }

            lastStatus = status

            if faultStates.contains(status) {
                return [
                    "resource": .string(resource),
                    "id": .string(id),
                    "region": .string(region),
                    "status": .string(status),
                    "fault": .bool(true),
                    "message": .string("\(resource) \(id) reached fault state \(status)"),
                    "elapsedSeconds": .float(elapsed(start)),
                    "polls": .integer(polls),
                ]
            }

            if targets.contains(status) {
                return [
                    "resource": .string(resource),
                    "id": .string(id),
                    "region": .string(region),
                    "status": .string(status),
                    "elapsedSeconds": .float(elapsed(start)),
                    "polls": .integer(polls),
                ]
            }

            // Progress notification with the current status and elapsed seconds
            if let server, let progressToken {
                await sendProgress(server: server, token: progressToken, status: status, elapsed: elapsed(start))
            }

            // Sleep with backoff, but never past the timeout
            let sleepTime = min(backoff, timeoutDate.timeIntervalSince(Date()))
            guard sleepTime > 0 else { break }
            try await Task.sleep(for: .seconds(sleepTime))
            backoff = min(backoff * 2, cap)
        }

        throw OpenStackError(
            service: "mcp", status: 408, code: "timeout",
            message: "Timed out after \(Int(timeout))s waiting for \(resource) \(id) to reach [\(targets.sorted().joined(separator: ", "))]. Last status: \(lastStatus ?? "unknown")"
        )
    }

    /// Whether the resource exposes a status a waiter can poll. Mirrors the
    /// pollable set in `getRaw`.
    private func supportsWaiting(_ descriptor: ResourceDescriptor) -> Bool {
        switch descriptor.service {
        case .compute: return descriptor.name == "server"
        case .network: return ["network", "subnet", "port", "router", "floating_ip"].contains(descriptor.name)
        case .blockStorage: return descriptor.name == "volume"
        case .image: return descriptor.name == "image"
        case .identity: return false
        case .objectStorage: return false
        case .keyManager: return descriptor.name == "secret"
        case .loadBalancer: return descriptor.name == "load_balancer"
        case .dns: return descriptor.name == "zone"
        case .containerInfra: return descriptor.name == "cluster"
        }
    }

    private func fetchStatus(_ vt: ValidatedToken, descriptor: ResourceDescriptor, id: String, region: String) async -> (status: String, exists: Bool) {
        do {
            let raw = try await getRaw(vt, descriptor: descriptor, id: id, region: region)
            let status = raw["status"]?.stringValue ?? ""
            return (status, true)
        } catch {
            if let e = error as? OpenStackError, e.status == 404 {
                return ("", false)
            }
            // Transient errors: treat as not-found for this poll cycle? No —
            // surface them, but a 404 is the only meaningful "gone".
            logger.debug("wait poll error for \(descriptor.name) \(id): \(error.localizedDescription)")
            return ("", false)
        }
    }

    private func getRaw(_ vt: ValidatedToken, descriptor: ResourceDescriptor, id: String, region: String) async throws -> [String: JSONValue] {
        switch descriptor.service {
        case .compute:
            if descriptor.name == "server" {
                let r = await client.compute(region: region)
                let s = try await r.getServer(vt, id: id)
                return ["status": .string(s.status), "name": .string(s.name)]
            }
            if descriptor.name == "flavor" || descriptor.name == "keypair" || descriptor.name == "server_group" {
                throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
            }
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
        case .network:
            switch descriptor.name {
            case "network":
                let r = await client.network(region: region)
                let n = try await r.getNetwork(vt, id: id)
                return ["status": .string(n.status)]
            case "subnet":
                let r = await client.network(region: region)
                let s = try await r.getSubnet(vt, id: id)
                return ["status": .string("ACTIVE")]
            case "port":
                let r = await client.network(region: region)
                let p = try await r.getPort(vt, id: id)
                return ["status": .string(p.status)]
            case "router":
                let r = await client.network(region: region)
                let ro = try await r.getRouter(vt, id: id)
                return ["status": .string(ro.status)]
            case "floating_ip":
                let r = await client.network(region: region)
                let f = try await r.getFloatingIP(vt, id: id)
                return ["status": .string(f.status)]
            default:
                throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
            }
        case .blockStorage:
            if descriptor.name == "volume" {
                let r = await client.blockStorage(region: region)
                let v = try await r.getVolume(vt, id: id)
                return ["status": .string(v.status)]
            }
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
        case .image:
            if descriptor.name == "image" {
                let r = await client.image(region: region)
                let img = try await r.getImage(vt, id: id)
                return ["status": .string(img.status)]
            }
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
        case .identity:
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on identity resources not supported")
        case .objectStorage:
            // Swift containers/objects have no status a waiter can poll.
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on object-storage resources not supported")
        case .keyManager:
            if descriptor.name == "secret" {
                let r = await client.keyManager(region: region)
                let s = try await r.getSecret(vt, id: id)
                return ["status": .string(s.status)]
            }
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
        case .loadBalancer:
            if descriptor.name == "load_balancer" {
                let r = await client.loadBalancer(region: region)
                let lb = try await r.getLoadBalancer(vt, id: id)
                return ["status": .string(lb.provisioning_status)]
            }
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
        case .dns:
            if descriptor.name == "zone" {
                let r = await client.dns(region: region)
                let z = try await r.getZone(vt, id: id)
                return ["status": .string(z.status)]
            }
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
        case .containerInfra:
            if descriptor.name == "cluster" {
                let r = await client.containerInfra(region: region)
                let c = try await r.getContainer(vt, id: id)
                return ["status": .string(c.status)]
            }
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
        }
    }

    private func elapsed(_ start: Date) -> Double {
        let s = Date().timeIntervalSince(start)
        return (s * 10).rounded() / 10
    }

    private func sendProgress(server: MCP.Server, token: ProgressToken, status: String, elapsed: Double) async {
        let message = Message<ProgressNotification>(
            method: ProgressNotification.name,
            params: ProgressNotification.Parameters(
                progressToken: token,
                progress: elapsed,
                total: nil,
                message: "status: \(status), elapsed: \(String(format: "%.1f", elapsed))s"
            )
        )
        try? await server.notify(message)
    }
}
