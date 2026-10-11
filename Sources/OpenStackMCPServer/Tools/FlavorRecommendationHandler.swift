import Foundation
import MCP
import OpenStackClient

/// Maps a plain-English workload description to the flavor families that fit it
/// (Rackspace-style naming: `gp.*` general purpose, `hr.*` high RAM,
/// `hc.*` high compute, `hd.*` high disk), filters by minimum vCPU/RAM, and
/// returns the top 3 candidates with a human-readable reason plus a volume
/// type pairing. See `os_recommend_flavor`.
extension ToolRegistry {
    func handleRecommendFlavor(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let region = try await resolveRegion(params)
        let vt = identity.vt
        let workload = argOptional(params, "workload")?.lowercased() ?? ""
        let minVcpu = argInt(params, "min_vcpu")
        let minRamGb = argInt(params, "min_ram_gb")

        let flavors = try await client.compute(region: region).listFlavors(vt)
        let totalAvailable = flavors.count

        // Workload keyword → preferred flavor family prefix + scoring mode.
        enum Profile { case ramHeavy, general, computeHeavy, diskHeavy }
        var profile: Profile = .general
        var preferredPrefixes: [String] = ["gp"]
        if ["database", "postgres", "redis", "cache", "memory"].contains(where: { !$0.isEmpty && workload.contains($0) }) {
            profile = .ramHeavy
            preferredPrefixes = ["hr", "gp"]
        } else if ["web", "api", "frontend", "general", "app"].contains(where: { !$0.isEmpty && workload.contains($0) }) {
            profile = .general
            preferredPrefixes = ["gp"]
        } else if ["compute", "hpc", "render", "compile", "batch"].contains(where: { !$0.isEmpty && workload.contains($0) }) {
            profile = .computeHeavy
            preferredPrefixes = ["hc", "gp"]
        } else if ["storage", "data", "backup", "archive"].contains(where: { !$0.isEmpty && workload.contains($0) }) {
            profile = .diskHeavy
            preferredPrefixes = ["hd", "gp"]
        }

        // Filter by explicit minimums, then score each surviving flavor.
        struct Scored { let flavor: Flavor; let score: Double; let reason: String }
        var scored: [Scored] = []
        for f in flavors {
            guard let vcpus = f.vcpus, let ramMb = f.ram else { continue }
            if let minVcpu, vcpus < minVcpu { continue }
            if let minRamGb, ramMb / 1024 < minRamGb { continue }
            let name = (f.name ?? "").lowercased()
            let diskGb = f.disk ?? 0
            let ratio = vcpus > 0 ? Double(ramMb) / 1024 / Double(vcpus) : 0
            let ramGb = ramMb / 1024

            let base: Double
            switch profile {
            case .ramHeavy:
                base = ratio * 10
            case .computeHeavy:
                base = Double(vcpus) * 10
            case .diskHeavy:
                base = Double(diskGb) / 10
            case .general:
                // Balanced: reward neither extreme — normalized sum of specs.
                base = Double(vcpus) * 2 + Double(ramGb) / 8 + Double(diskGb) / 20
            }
            let familyMatch = preferredPrefixes.first { name.hasPrefix($0) } != nil
            let score = base + (familyMatch ? 100 : 0)

            let reason: String
            if familyMatch {
                switch profile {
                case .ramHeavy:
                    reason = "High-RAM flavor (\(vcpus) vCPU / \(ramGb) GB) suits memory-intensive workloads"
                case .computeHeavy:
                    reason = "High-compute flavor (\(vcpus) vCPU) suits CPU-bound workloads"
                case .diskHeavy:
                    reason = "High-disk flavor (\(diskGb) GB local disk) suits storage-heavy workloads"
                case .general:
                    reason = "General-purpose flavor with balanced vCPU/RAM/disk"
                }
            } else {
                switch profile {
                case .ramHeavy:
                    reason = "Balanced flavor with \(ramGb) GB RAM per \(vcpus) vCPU (no high-RAM family available)"
                case .computeHeavy:
                    reason = "Balanced flavor with \(vcpus) vCPUs (no high-compute family available)"
                case .diskHeavy:
                    reason = "Balanced flavor with \(diskGb) GB disk (no high-disk family available)"
                case .general:
                    reason = "Balanced general-purpose flavor"
                }
            }
            scored.append(Scored(flavor: f, score: score, reason: reason))
        }

        scored.sort { $0.score > $1.score }
        let top = Array(scored.prefix(3))

        let recommendations: [[String: JSONValue]] = top.map { s -> [String: JSONValue] in
            [
                "name": .string(s.flavor.name ?? s.flavor.id),
                "id": .string(s.flavor.id),
                "vcpus": .integer(s.flavor.vcpus ?? 0),
                "ram_gb": .integer((s.flavor.ram ?? 0) / 1024),
                "disk_gb": .integer(s.flavor.disk ?? 0),
                "reason": .string(s.reason),
            ]
        }

        let volumeType: String
        switch profile {
        case .ramHeavy, .diskHeavy:
            volumeType = "HA-Performance"
        default:
            volumeType = "SSD-Standard"
        }

        var result: [String: JSONValue] = [
            "workload": .string(workload),
            "recommendations": .array(recommendations.map { .object($0) }),
            "volume_type_recommendation": .string(volumeType),
            "total_available": .integer(totalAvailable),
        ]
        if top.isEmpty {
            result["message"] = .string("No flavors match the specified requirements")
        }
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }
}
