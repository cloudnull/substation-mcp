import Foundation
import MCP
import OpenStackClient

/// Maps a plain-English workload description to the flavor families that fit it
/// (Rackspace-style naming: `gp.*` general purpose, `hr.*` high RAM,
/// `hc.*` high compute, `hd.*` high disk), filters by minimum vCPU/RAM, and
/// returns the smallest flavors that satisfy the request with a human-readable
/// reason plus a volume type pairing. See `os_recommend_flavor`.
extension ToolRegistry {

    // MARK: - Workload inference

    /// Shape of the requirement derived from the free-text `workload`.
    ///
    /// `vcpu`/`ramGb` are soft targets: the recommender surfaces them in the
    /// result so an agent or operator can see what was guessed and override it
    /// with explicit `min_vcpu` / `min_ram_gb`. `familyBoost` is *not* a size
    /// requirement: it selects the family label, the volume-type pairing and the
    /// per-flavor reason, never how big the machine must be.
    struct WorkloadRequirement: Sendable {
        var vcpu: Int
        var ramGb: Int
        var familyBoost: [String]
        var familyLabel: String
        /// True when nothing in the workload text matched a known keyword.
        var defaulted: Bool
        /// The matched keyword, when one matched.
        var matchedKeyword: String?
        /// True when a size-signal word (large/medium/small/…) set the tier.
        var scaledFromText: Bool
    }

    /// Size tiers a workload description can imply, in ascending order.
    private enum SizeTier: Int, CaseIterable {
        case tiny, small, medium, large, huge

        /// (vCPU, RAM GB) target for a general-purpose workload in this tier.
        ///
        /// Deliberately conservative: a vague workload must never produce a
        /// large requirement, because the recommender hands its first entry to
        /// an agent that provisions it without questioning it.
        var generalShape: (vcpu: Int, ramGb: Int) {
            switch self {
            case .tiny:   return (1, 1)
            case .small:  return (1, 2)
            case .medium: return (2, 4)
            case .large:  return (4, 16)
            case .huge:   return (8, 32)
            }
        }

        /// How hard a RAM-skewed family pushes the RAM target above the
        /// general-purpose shape, as a GB-per-vCPU floor. `0` means "keep the
        /// general-purpose shape" — a tiny instance is never a high-RAM box.
        var ramPerVcpuFloor: Int {
            switch self {
            case .tiny: return 0
            case .small: return 1
            case .medium: return 2
            case .large: return 4
            case .huge: return 4
            }
        }
    }

    /// Workload keyword → (family prefixes, family label, RAM GB per vCPU).
    ///
    /// The ratio is a *bias*, not a floor: it decides which family and which
    /// RAM-per-vCPU shape is preferred at a given vCPU count. It never inflates
    /// the requested size on its own.
    private static let workloadFamilies: [(keywords: [String], prefixes: [String], label: String, ramPerVcpu: Int)] = [
        (["database", "postgres", "mysql", "mariadb", "redis", "memcached", "cache", "in-memory", "in memory", "memory", "analytics", "spark"],
         ["hr", "mo", "gp"], "high-RAM", 4),
        (["compute", "hpc", "render", "compile", "batch", "build", "transcode", "encod", "simulation", "quantum", "ml", "machine learning", "training", "inference"],
         ["hc", "co", "gp"], "high-compute", 2),
        (["storage", "backup", "archive", "filesystem", "file share", "nfs", "smb", "log"],
         ["hd", "gp"], "high-disk", 1),
        // Broadest list, so it is checked last and catches web/api/app/general.
        (["web", "api", "frontend", "backend", "app", "service", "worker", "general", "python", "node", "django", "flask", "fastapi", "static", "proxy", "reverse proxy"],
         ["gp"], "general-purpose", 2),
    ]

    /// Ascending size signals. Ordered longest-first per tier so "xlarge" is
    /// claimed by `.huge` and never mis-read as the "large" inside it.
    private static let sizeSignals: [(words: [String], tier: SizeTier)] = [
        (["extra-large", "extra large", "xlarge", "xxlarge", "xxxlarge", "jumbo", "massive", "beast"], .huge),
        (["large", "big", "heavy", "busy", "high-traffic", "high traffic", "production", "prod", "enterprise", "many users"], .large),
        (["medium", "mid-size", "mid size", "moderate"], .medium),
        (["small", "tiny", "little", "light", "lite", "minimal", "hello world", "helloworld", "hello-world", "dev", "development", "testing", "staging", "poc", "proof of concept", "trial", "micro"], .small),
    ]

    /// Words that mean "this is a micro instance" and pull the target down a
    /// tier (floored at `.tiny`).
    private static let shrinkSignals = ["nano", "nano instance", "single-threaded", "single threaded", "sidecar"]

    /// Turns the free-text workload into a conservative size target plus a
    /// family bias. Unknown / empty text defaults to the smallest useful
    /// general-purpose shape (1 vCPU / 2 GB) rather than to "no opinion",
    /// because "no opinion" used to mean "rank the biggest flavor first".
    static func inferWorkloadRequirement(_ workload: String) -> WorkloadRequirement {
        let text = workload.lowercased()
        var family = (prefixes: ["gp"], label: "general-purpose", ramPerVcpu: 2)
        var matchedKeyword: String?
        for entry in workloadFamilies where matchedKeyword == nil {
            if let kw = entry.keywords.first(where: { !$0.isEmpty && text.contains($0) }) {
                family = (entry.prefixes, entry.label, entry.ramPerVcpu)
                matchedKeyword = kw
            }
        }
        let defaulted = matchedKeyword == nil

        var tier = SizeTier.small
        var scaledFromText = false
        for signal in sizeSignals {
            if signal.words.contains(where: { text.contains($0) }) {
                tier = signal.tier
                scaledFromText = true
                break
            }
        }
        if !scaledFromText, shrinkSignals.contains(where: { text.contains($0) }), tier.rawValue > 0 {
            tier = SizeTier(rawValue: tier.rawValue - 1) ?? .tiny
        }

        let general = tier.generalShape
        let vcpu = max(1, general.vcpu)
        // A RAM-skewed family (ratio > the general-purpose 2 GB/vCPU) lifts the
        // RAM target to its own ratio, but only as far as the tier allows -
        // `ramPerVcpuFloor` is 0 for `.tiny`, so a nano instance stays small
        // even if the text mentions "cache". Families at or below the general
        // ratio keep the tier shape. Lifting the vCPU target to `ram / ratio`
        // was the wrong coupling: it turned "database" into a 2-vCPU demand and
        // filtered out `hr.0.1.8` (1 vCPU / 8 GB), the flavor a database caller
        // should be offered first.
        let skew = family.ramPerVcpu > 2 ? tier.ramPerVcpuFloor : 0
        let ramGb = max(general.ramGb, skew > 0 ? vcpu * skew : 0)
        return WorkloadRequirement(
            vcpu: vcpu,
            ramGb: max(1, ramGb),
            familyBoost: family.prefixes,
            familyLabel: family.label,
            defaulted: defaulted,
            matchedKeyword: matchedKeyword,
            scaledFromText: scaledFromText
        )
    }

    /// A flavor that cleared the caller's minimums, with the fields the ranking
    /// and the reason string need. Extension scope so the reason builder can
    /// take it as a parameter.
    struct Ranked: Sendable {
        let flavor: Flavor
        let vcpus: Int
        let ramGb: Int
        let diskGb: Int
        /// Position of the flavor's family in the workload's preferred prefix
        /// list: `0` for the most preferred family, `familyBoost.count` when the
        /// flavor belongs to none of them.
        ///
        /// The list is ordered most-preferred-first (`["hr","mo","gp"]` for a
        /// database, `["gp"]` for a web app), so this is what makes a database
        /// reach for `hr.0.1.8` ahead of `gp.0.1.2` — both are acceptable
        /// families, one is preferred. It is the leading sort key, ahead of
        /// size: a family the workload asked for is offered before a bigger or
        /// smaller machine from a family it did not. Within one family the order
        /// is smallest-that-fits first, so preferring a family never buys size.
        let familyRank: Int
    }

    func handleRecommendFlavor(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let region = try await resolveRegion(params)
        let vt = identity.vt
        let workload = argOptional(params, "workload")?.lowercased() ?? ""
        let minVcpu = argInt(params, "min_vcpu")
        let minRamGb = argInt(params, "min_ram_gb")

        let flavors = try await client.compute(region: region).listFlavors(vt)
        let totalAvailable = flavors.count
        let inferred = Self.inferWorkloadRequirement(workload)
        // The hard floors. A stated minimum always filters. The inferred *vCPU*
        // target also filters, because it is the one axis a vague workload
        // cannot get wrong in the dangerous direction: without it, "large
        // production database" (4 vCPU) is answered with `gp.0.1.2`, and an
        // inferred target above the whole catalogue is answered with the biggest
        // box on the shelf — the oversized-flavor bug this recommender exists to
        // stop.
        //
        // The inferred *RAM* target never filters. It is a shape statement
        // derived from the family ratio (`ramPerVcpuFloor`), not a sizing one,
        // and folding it into a floor with `max()` deleted `gp.0.4.8` from the
        // candidate set for `min_ram_gb: 8` on a small-text workload, leaving the
        // 1 vCPU `hr.0.1.8` as the only answer. A floor the caller can see in the
        // output is the point; a floor invented by inference on the axis they
        // said nothing about is not.
        let vcpuFloor = max(minVcpu ?? 0, inferred.vcpu)
        let reportedVcpuFloor = minVcpu ?? inferred.vcpu
        let reportedRamFloor = minRamGb ?? inferred.ramGb

        var ranked: [Ranked] = []
        for f in flavors {
            // A flavor whose specs the cloud did not report cannot be checked
            // against a floor, so it is never offered. Rackspace's plain
            // GET /flavors answers {id,name,links} with no specs at all, so
            // these are absent rather than zero; a zero is a real (useless)
            // spec and is excluded by the floors anyway.
            guard let vcpus = f.vcpus, let ramMb = f.ram, vcpus > 0, ramMb > 0 else { continue }
            // Hard floors.
            if vcpus < vcpuFloor { continue }
            if let minVcpu, vcpus < minVcpu { continue }
            if let minRamGb, ramMb / 1024 < minRamGb { continue }
            let name = (f.name ?? "").lowercased()
            let ramGb = ramMb / 1024
            ranked.append(Ranked(
                flavor: f,
                vcpus: vcpus,
                ramGb: ramGb,
                diskGb: f.disk ?? 0,
                familyRank: inferred.familyBoost.firstIndex { name.hasPrefix($0) }
                    ?? inferred.familyBoost.count
            ))
        }

        // Ranked client-side: Nova's list endpoint cannot express this
        // ordering, `sort_key` is restricted to
        // created_at/description/disabled/ephemeral_gb/flavorid/id/is_public/
        // memory_mb/name/root_gb/rxtx_factor/swap/updated_at/vcpu_weight/vcpus
        // (nova api-ref/source/parameters.yaml, `sort_key_flavor`; default
        // `flavorid`), so no single request ranks by fit, and Rackspace IAD3
        // returns the catalogue largest-first.
        //
        // Preferred family first, then smallest-that-fits: family rank, vCPU,
        // RAM, disk, name. A plain lexicographic order, not a "distance from the
        // requirement" score.
        //
        // Family leads because it is the one thing the workload text actually
        // states: "database" asks for high-RAM, "web app" for general purpose.
        // Size leads *within* a family, so a preference can pick which box of a
        // given shape to start from but can never buy a bigger machine — a
        // database gets `hr.0.1.8` (1 vCPU / 8 GB), not `hr.0.8.32`, and a web
        // app gets `gp.0.1.2`, not `gp.0.48.192`.
        //
        // vCPU and RAM GB are never summed into one distance: they are not
        // commensurable, and a combined figure lets a surplus on one axis pay
        // for a deficit on the other. That bug was live — ranking
        // `min_ram_gb: 8` on total overage offered the 1 vCPU `hr.0.1.8` ahead of
        // the 4 vCPU `gp.0.4.8`, because 7 GB of unasked-for RAM looked cheaper
        // than 3 vCPU of compute. A recommender whose first entry an agent
        // provisions without questioning it must not under-size the machine to
        // win on one axis.
        //
        // The floors above make "smallest first" safe: everything here already
        // meets the caller's `min_vcpu` / `min_ram_gb` and the inferred vCPU
        // target, so nothing under-provisioned can be offered.
        ranked.sort { a, b in
            if a.familyRank != b.familyRank { return a.familyRank < b.familyRank }
            if a.vcpus != b.vcpus { return a.vcpus < b.vcpus }
            if a.ramGb != b.ramGb { return a.ramGb < b.ramGb }
            if a.diskGb != b.diskGb { return a.diskGb < b.diskGb }
            return (a.flavor.name ?? a.flavor.id) < (b.flavor.name ?? b.flavor.id)
        }
        let top = Array(ranked.prefix(3))

        let recommendations: [[String: JSONValue]] = top.map { r -> [String: JSONValue] in
            [
                "name": .string(r.flavor.name ?? r.flavor.id),
                "id": .string(r.flavor.id),
                "vcpus": .integer(r.vcpus),
                "ram_gb": .integer(r.ramGb),
                "disk_gb": .integer(r.diskGb),
                "reason": .string(Self.recommendationReason(
                    for: r, requirement: inferred,
                    vcpuFloor: reportedVcpuFloor, ramFloor: reportedRamFloor
                )),
            ]
        }

        // Same pairing rule as before: RAM/disk-skewed workloads get the
        // performance tier, everything else the standard SSD tier.
        let volumeType = (inferred.familyLabel == "high-RAM" || inferred.familyLabel == "high-disk") ? "HA-Performance" : "SSD-Standard"

        var result: [String: JSONValue] = [
            "workload": .string(workload),
            "recommendations": .array(recommendations.map { .object($0) }),
            "volume_type_recommendation": .string(volumeType),
            "total_available": .integer(totalAvailable),
            "inferred_requirements": .object([
                "min_vcpu": .integer(reportedVcpuFloor),
                "min_ram_gb": .integer(reportedRamFloor),
                "family": .string(inferred.familyLabel),
                "defaulted": .bool(inferred.defaulted),
                "from_explicit_minimums": .bool(minVcpu != nil || minRamGb != nil),
                "basis": .string(Self.requirementBasis(inferred: inferred, workload: workload, minVcpu: minVcpu, minRamGb: minRamGb)),
            ]),
            // The ranking rule, surfaced so a consuming agent can tell that the
            // first entry is the *cheapest fit* and not the biggest option.
            "ranking": .string("smallest_fits_first"),
        ]
        if top.isEmpty {
            result["message"] = .string("No flavors match the specified requirements")
            result["hint"] = .string("Lower min_vcpu / min_ram_gb, or check the flavors with os_list(resource: \"flavor\"). The requirement above may be inferred from the workload text rather than requested.")
        }
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    // MARK: - Reasoning strings

    private static func recommendationReason(for r: Ranked, requirement: WorkloadRequirement, vcpuFloor: Int, ramFloor: Int) -> String {
        let specs = "\(r.vcpus) vCPU / \(r.ramGb) GB"
        let fit = r.familyRank < requirement.familyBoost.count
            ? "\(requirement.familyLabel) family"
            : "balanced \(r.ramGb) GB per \(r.vcpus) vCPU (\(requirement.familyLabel) family not offered)"
        return "Smallest flavor that fits \(specs) — \(fit); meets the \(vcpuFloor) vCPU / \(ramFloor) GB requirement"
    }

    private static func requirementBasis(inferred: WorkloadRequirement, workload: String, minVcpu: Int?, minRamGb: Int?) -> String {
        var parts: [String] = []
        if inferred.defaulted {
            parts.append(workload.isEmpty
                ? "no workload text supplied, so the smallest useful general-purpose shape (1 vCPU / 2 GB) was assumed"
                : "no known workload keyword in \"\(workload)\", so the smallest useful general-purpose shape (1 vCPU / 2 GB) was assumed")
        } else if inferred.scaledFromText {
            parts.append("sized from a size word in the workload text (\(inferred.familyLabel) family)")
        } else {
            parts.append("matched \"\(inferred.matchedKeyword ?? "")\" → \(inferred.familyLabel) family at the conservative small tier")
        }
        if minVcpu != nil || minRamGb != nil {
            parts.append("explicit min_vcpu/min_ram_gb are hard floors; the inferred target still picks the preferred shape")
        }
        return parts.joined(separator: "; ")
    }
}
