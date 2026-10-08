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

    public init(client: OpenStackClient, catalog: ResourceCatalog, logger: Logger = Logger(label: "substation-mcp-waiter")) {
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
            let outcome = await fetchStatus(vt, descriptor: descriptor, id: id, region: region)

            switch outcome {
            case .transient(let error):
                // A fetch error that is NOT a confirmed 404 (e.g. Nova 500/503,
                // Keystone flap) is transient. Keep polling — it must never be
                // reported as deletion or "resource no longer exists". The last
                // observed status is deliberately left untouched so a later
                // timeout still reports a real state, not the error.
                logger.debug("wait poll transient error for \(descriptor.name) \(id): \(error.localizedDescription)")

            case .gone:
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
                // Confirmed 404: the resource vanished while waiting for a state.
                throw OpenStackError(
                    service: "mcp", status: 404, code: "itemNotFound",
                    message: "Resource \(resource) \(id) no longer exists (last status: \(lastStatus ?? "unknown"))"
                )

            case .found(let status):
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

    /// One-shot, non-looping read of a resource's current status string. Used
    /// by the task shim to make `os_task_submit` responses informative without
    /// blocking on the settle. Reuses the same per-service `getRaw` switch as
    /// the polling loop.
    public func probeStatus(_ vt: ValidatedToken, descriptor: ResourceDescriptor, id: String, region: String) async throws -> String {
        let raw = try await getRaw(vt, descriptor: descriptor, id: id, region: region)
        return raw["status"]?.stringValue ?? ""
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
        case .orchestration: return descriptor.name == "stack"
        case .sharev2: return descriptor.name == "share"
        case .placement: return false
        case .database: return descriptor.name == "database_instance"
        case .metric: return false
        case .messaging: return false
        case .reservation: return descriptor.name == "reservation"
        case .backup: return false
        case .cloudformation: return false
        }
    }

    /// The outcome of a single status fetch. Distinguishes "resource exists
    /// with this status" from "resource confirmed gone (true 404)" from
    /// "fetch failed transiently". The old `(status, exists)` tuple collapsed
    /// *every* non-404 error (Nova 500/503, Keystone flap, 429, ...) into
    /// "not exists", which a poll loop could then misreport as deletion or
    /// "resource no longer exists".
    private enum FetchOutcome {
        case found(status: String)
        case gone
        case transient(underlying: Error)
    }

    private func fetchStatus(_ vt: ValidatedToken, descriptor: ResourceDescriptor, id: String, region: String) async -> FetchOutcome {
        do {
            let raw = try await getRaw(vt, descriptor: descriptor, id: id, region: region)
            let status = raw["status"]?.stringValue ?? ""
            return .found(status: status)
        } catch {
            if let e = error as? OpenStackError, e.status == 404 {
                return .gone
            }
            // Any other error is transient: the poll loop keeps waiting
            // instead of treating the resource as gone.
            return .transient(underlying: error)
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
                _ = try await r.getSubnet(vt, id: id)
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
        case .orchestration:
            if descriptor.name == "stack" {
                let r = await client.orchestration(region: region)
                let s = try await r.getStack(vt, id: id)
                return ["status": .string(s.status)]
            }
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
        case .sharev2:
            if descriptor.name == "share" {
                let r = await client.share(region: region)
                let s = try await r.getShare(vt, id: id)
                return ["status": .string(s.status)]
            }
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
        case .placement:
            // Resource providers have no lifecycle status a waiter can poll.
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on placement resources not supported")
        case .database:
            if descriptor.name == "database_instance" {
                let r = await client.database(region: region)
                let i = try await r.getInstance(vt, id: id)
                return ["status": .string(i.status)]
            }
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
        case .metric:
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on metric resources not supported")
        case .messaging:
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on messaging resources not supported")
        case .reservation:
            if descriptor.name == "reservation" {
                let r = await client.reservation(region: region)
                let res = try await r.getReservation(vt, id: id)
                return ["status": .string(res.status)]
            }
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on \(descriptor.name) not supported")
        case .backup:
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on backup resources not supported")
        case .cloudformation:
            throw OpenStackError(service: "mcp", status: 501, message: "Waiting on cloudformation resources not supported")
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
