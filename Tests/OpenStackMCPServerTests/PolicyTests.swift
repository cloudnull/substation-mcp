import Testing
import Foundation
import OpenStackMCPServer

@Suite("Policy Tests")
struct PolicyTests {
    let catalog = ResourceCatalog.phase1()

    @Test("default policy denies exactly the six identity-admin names")
    func defaultDenyResources() {
        let policy = Policy()
        let expected: Set<String> = ["project", "user", "group", "role", "role_assignment", "domain"]
        #expect(policy.denyResources == expected, "Expected \(expected), got \(policy.denyResources)")
    }

    @Test("effective catalog removes denied resources")
    func effectiveRemovesDenied() {
        let policy = Policy()
        let effective = policy.effective(catalog)

        for name in ["project", "user", "group", "role", "role_assignment", "domain"] {
            #expect(effective.descriptor(name) == nil, "\(name) should be denied")
        }

        // Non-denied resources remain
        #expect(effective.descriptor("server") != nil, "server should not be denied")
        #expect(effective.descriptor("network") != nil, "network should not be denied")
        #expect(effective.descriptor("volume") != nil, "volume should not be denied")
        #expect(effective.descriptor("image") != nil, "image should not be denied")
        #expect(effective.descriptor("region") != nil, "region should not be denied")
        #expect(effective.descriptor("service") != nil, "service should not be denied")
    }

    @Test("read-only tool set has 9 verb tools + 3 task tools")
    func readOnlyToolSet() {
        let policy = Policy(readOnly: true)
        let tools = policy.toolsEnabled()
        #expect(tools.count == 12, "Expected 12 read-only tools, got \(tools.count): \(tools.sorted())")
        let expected: Set<String> = [
            "os_list", "os_get", "os_describe", "os_topology",
            "os_find", "os_whoami", "os_quota", "os_clouds", "os_wait",
            "os_task_submit", "os_task_status", "os_task_cancel"
        ]
        #expect(tools == expected)
    }

    @Test("denyVerbs removes specific verbs from descriptor")
    func denyVerbs() {
        let policy = Policy(denyVerbs: ["server": [.delete]])
        let effective = policy.effective(catalog)
        let server = effective.descriptor("server")!
        #expect(!server.verbs.contains(.delete), "server.delete should be denied")
        #expect(server.verbs.contains(.list), "server.list should remain")
        #expect(server.verbs.contains(.create), "server.create should remain")
    }

    @Test("denyActions removes specific actions from descriptor")
    func denyActions() {
        let policy = Policy(denyActions: ["server": ["evacuate", "live_migrate", "migrate"]])
        let effective = policy.effective(catalog)
        let server = effective.descriptor("server")!
        let actionNames = Set(server.actions.map(\.name))
        #expect(!actionNames.contains("evacuate"), "evacuate should be denied")
        #expect(!actionNames.contains("live_migrate"), "live_migrate should be denied")
        #expect(!actionNames.contains("migrate"), "migrate should be denied")
        #expect(actionNames.contains("reboot"), "reboot should remain")
        #expect(actionNames.contains("start"), "start should remain")
    }

    @Test("maxListLimit is exposed")
    func maxListLimit() {
        let policy = Policy()
        #expect(policy.maxListLimit == 200)

        let custom = Policy(maxListLimit: 50)
        #expect(custom.maxListLimit == 50)
    }

    @Test("maxCallsPerMinute is exposed")
    func maxCallsPerMinute() {
        let policy = Policy()
        #expect(policy.maxCallsPerMinute == 1024)
    }

    @Test("effective catalog preserves non-denied resource verbs")
    func effectivePreservesVerbs() {
        let policy = Policy()
        let effective = policy.effective(catalog)
        let image = effective.descriptor("image")!
        #expect(image.verbs == [.list, .get, .create, .update, .delete])
    }
}
