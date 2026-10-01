import Testing
import Foundation
import OpenStackClient
@testable import OpenStackMCPServer

// MARK: - access-rules generator (spec §11.3)

/// Tests the `AccessRulesGenerator` against the pinned `AccessRulePaths`
/// constants (not re-hardcoded strings) and the read-only / service / resource
/// filters.
@Suite("Access Rules", .timeLimit(.minutes(2)))
struct AccessRulesTests {

    private func set(_ rules: [Rule]) -> Set<String> {
        Set(rules.map { "\($0.service)|\($0.method)|\($0.path)" })
    }

    @Test("read-only mode emits only GET methods")
    func readOnlyIsGETOnly() throws {
        let rules = AccessRulesGenerator.generate(readOnly: true, neutronExtensions: ["address-group"])
        #expect(!rules.isEmpty)
        #expect(rules.allSatisfy { $0.method == "GET" })
    }

    @Test("read-only output has only GET; every rule has service/method/path")
    func readOnlyShape() throws {
        let rules = AccessRulesGenerator.generate(readOnly: true)
        for r in rules {
            #expect(!r.service.isEmpty)
            #expect(!r.method.isEmpty)
            #expect(!r.path.isEmpty)
            #expect(r.method == "GET")
        }
        // whoami needs GET /users/*/application_credentials/* (read-only path).
        let s = set(rules)
        #expect(s.contains("identity|GET|/users/*/application_credentials/*"))
        // Default policy denies identity-admin writes: POST /projects absent.
        #expect(!s.contains("identity|POST|/projects"))
    }

    @Test("operator mode is a superset of read-only and includes mutating rules")
    func operatorSuperset() throws {
        let ro = set(AccessRulesGenerator.generate(readOnly: true, neutronExtensions: ["address-group"]))
        let op = set(AccessRulesGenerator.generate(readOnly: false, neutronExtensions: ["address-group"]))
        #expect(ro.isSubset(of: op), "read-only rules must be a subset of operator rules")

        // Pinned mutating rules (assert against the constants, not re-hardcoded).
        let compute = set(AccessRulePaths.compute)
        #expect(compute.contains("compute|POST|/servers"))
        #expect(compute.contains("compute|DELETE|/servers/*"))
        #expect(compute.contains("compute|POST|/servers/*/action"))
        let network = set(AccessRulePaths.network)
        #expect(network.contains("network|PUT|/v2.0/routers/*/add_router_interface"))
        #expect(network.contains("network|PUT|/v2.0/routers/*/remove_router_interface"))
        let cinder = set(AccessRulePaths.blockStorage)
        #expect(cinder.contains("blockStorage|POST|/volumes/*/extend"))
        #expect(cinder.contains("blockStorage|POST|/volumes/*/set_bootable"))
        // All of these must be in the operator output.
        for pinned in ["compute|POST|/servers", "compute|DELETE|/servers/*",
                       "compute|POST|/servers/*/action",
                       "network|PUT|/v2.0/routers/*/add_router_interface",
                       "blockStorage|POST|/volumes/*/extend"] {
            #expect(op.contains(pinned), "operator rules missing \(pinned)")
        }
    }

    @Test("--services compute filters out network rules")
    func serviceFilter() throws {
        let rules = AccessRulesGenerator.generate(readOnly: false, services: ["compute"])
        #expect(!rules.isEmpty)
        #expect(rules.allSatisfy { $0.service == "compute" })
        #expect(!rules.contains { $0.service == "network" })
    }

    @Test("address-group rules are emitted only when the extension is present")
    func addressGroupGate() throws {
        let withExt = set(AccessRulesGenerator.generate(readOnly: false, neutronExtensions: ["address-group"]))
        let withoutExt = set(AccessRulesGenerator.generate(readOnly: false, neutronExtensions: []))
        #expect(withExt.contains("network|GET|/v2.0/address-groups"))
        #expect(!withoutExt.contains("network|GET|/v2.0/address-groups"))
    }

    @Test("the JSON output wraps rules in {\"rules\": [...]}")
    func jsonShape() throws {
        let json = try AccessRulesGenerator.json(readOnly: false, neutronExtensions: ["address-group"])
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rules = obj["rules"] as! [[String: Any]]
        #expect(!rules.isEmpty)
        for r in rules {
            #expect(r["service"] is String)
            #expect(r["method"] is String)
            #expect(r["path"] is String)
        }
    }
}
