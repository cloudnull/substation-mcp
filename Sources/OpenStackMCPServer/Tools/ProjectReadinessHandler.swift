import Foundation
import MCP
import OpenStackClient

/// Aggregates the project's infrastructure state into a single "what can I do
/// right now" view for non-expert harnesses: networks, routers, volume quotas,
/// flavors, keypairs, security groups, and a `blockers` list of missing
/// prerequisites. See `os_project_readiness`.
extension ToolRegistry {
    func handleProjectReadiness(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let region = try await resolveRegion(params)
        let vt = identity.vt

        // Gather all inputs in parallel; a failure in any service fails the call.
        async let nsTask = client.network(region: region)
        async let csTask = client.compute(region: region)
        async let bsTask = client.blockStorage(region: region)
        let ns = await nsTask
        let cs = await csTask
        let bs = await bsTask

        async let networks = ns.listNetworks(vt, filters: [:], limit: 200)
        async let routers = ns.listRouters(vt, filters: [:], limit: 100)
        async let sgs = ns.listSecurityGroups(vt, limit: 100)
        async let sgRules = ns.listSecurityGroupRules(vt, limit: 500)
        async let flavors = cs.listFlavors(vt)
        async let keypairs = cs.listKeypairs(vt)
        async let computeQuota = cs.getQuotaSet(vt)
        async let volumeQuota = bs.getQuota(vt)

        let (netList, routerList, sgList, ruleList, flavorList, kpList, cQuota, vQuota) =
            try await (networks, routers, sgs, sgRules, flavors, keypairs, computeQuota, volumeQuota)

        // Networks: private vs public.
        let privateNets = netList.filter { !$0.routerExternal }
        let publicNets = netList.filter { $0.routerExternal }

        // Routers with an external gateway.
        let gatewayRouters = routerList.filter { $0.externalGatewayInfo != nil }

        // Security groups with rule counts.
        let rulesBySG: [String: Int] = Dictionary(grouping: ruleList, by: { $0.securityGroupID }).mapValues(\.count)
        let sgItems: [[String: JSONValue]] = sgList.map { sg -> [String: JSONValue] in
            ["name": .string(sg.name), "id": .string(sg.id), "rules": .integer(rulesBySG[sg.id] ?? 0)]
        }

        // Flavors: count + compact list.
        let flavorItems: [[String: JSONValue]] = flavorList.map { f -> [String: JSONValue] in
            [
                "id": .string(f.id),
                "name": .string(f.name ?? ""),
                "vcpus": .integer(f.vcpus ?? 0),
                "ram": .integer(f.ram ?? 0),
                "disk": .integer(f.disk ?? 0),
            ]
        }

        // Keypair names.
        let kpNames: [JSONValue] = kpList.map { .string($0.name) }

        // Blockers: what is missing before servers can be deployed.
        var blockers: [String] = []
        if privateNets.isEmpty {
            blockers.append("No private network with router — create one before deploying servers (os_create network → subnet → router → router_interface)")
        }
        if kpList.isEmpty {
            blockers.append("No SSH keypairs — create one with os_create(keypair)")
        }
        if vQuota.volumes == 0 {
            blockers.append("Volume quota exhausted")
        }

        let result: [String: JSONValue] = [
            "region": .string(region),
            "networks": .object([
                "private": .array(privateNets.map { n -> JSONValue in .object(["id": .string(n.id), "name": .string(n.name)]) }),
                "public": .array(publicNets.map { n -> JSONValue in .object(["id": .string(n.id), "name": .string(n.name)]) }),
                "private_count": .integer(privateNets.count),
                "public_count": .integer(publicNets.count),
            ]),
            "routers": .object([
                "total": .integer(routerList.count),
                "with_external_gateway": .integer(gatewayRouters.count),
                "gateway_routers": .array(gatewayRouters.map { r -> JSONValue in .object(["id": .string(r.id), "name": .string(r.name)]) }),
            ]),
            "volumes": .object([
                "quota_volumes": .integer(vQuota.volumes),
                "quota_gigabytes": .integer(vQuota.gigabytes),
                "quota_snapshots": .integer(vQuota.snapshots),
            ]),
            "compute_quota": .object([
                "instances": .integer(cQuota.instances ?? 0),
                "cores": .integer(cQuota.cores ?? 0),
                "ram": .integer(cQuota.ram ?? 0),
                "key_pairs": .integer(cQuota.keyPairs ?? 0),
            ]),
            "flavors": .object([
                "count": .integer(flavorList.count),
                "items": .array(flavorItems.map { .object($0) }),
            ]),
            "keypairs": .object([
                "count": .integer(kpList.count),
                "names": .array(kpNames),
            ]),
            "security_groups": .object([
                "count": .integer(sgList.count),
                "items": .array(sgItems.map { .object($0) }),
            ]),
            "ready_for_servers": .bool(blockers.isEmpty),
            "blockers": .array(blockers.map { .string($0) }),
        ]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }
}
