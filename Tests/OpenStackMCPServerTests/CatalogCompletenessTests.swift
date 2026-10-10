import Testing
import Foundation
import OpenStackMCPServer

@Suite("Catalog Completeness Tests")
struct CatalogCompletenessTests {

    let catalog = ResourceCatalog.phase1()

    // MARK: - Schema completeness

    @Test("every descriptor with .create has a non-nil createSchema")
    func createSchemaPresence() {
        for d in catalog.resources where d.verbs.contains(.create) {
            #expect(d.createSchema != nil, "\(d.name): has .create but no createSchema")
        }
    }

    @Test("every descriptor with .update has a non-nil updateSchema")
    func updateSchemaPresence() {
        for d in catalog.resources where d.verbs.contains(.update) {
            #expect(d.updateSchema != nil, "\(d.name): has .update but no updateSchema")
        }
    }

    @Test("every descriptor has at least one verb")
    func hasVerbs() {
        for d in catalog.resources {
            #expect(!d.verbs.isEmpty, "\(d.name) has no verbs")
        }
    }

    // MARK: - Resource set (33 names, §8.5)

    @Test("resource set matches the 33-name phase-1 matrix")
    func resourceNames() {
        let expected: Set<String> = [
            // Identity (10)
            "region", "project", "user", "group", "role",
            "role_assignment", "domain", "service", "endpoint", "application_credential",
            // Compute (10)
            "server", "flavor", "keypair", "server_group", "availability_zone",
            "hypervisor", "compute_service", "server_interface", "server_volume_attachment", "compute_quota",
            // Network (9)
            "network", "subnet", "port", "router", "floating_ip",
            "security_group", "security_group_rule", "address_group", "network_quota",
            // Block storage (5)
            "volume", "volume_type", "volume_snapshot", "volume_backup", "volume_quota",
            // Image (1)
            "image",
            // Object storage (2) — phase 2
            "container", "object",
            // Key manager (2) — phase 2
            "secret", "secret_container",
            // Load balancer (5) — phase 2
            "load_balancer", "listener", "pool", "member", "health_monitor",
            // DNS (2) — phase 2
            "zone", "recordset",
            // Container infrastructure (2) — phase 2
            "cluster", "cluster_template",
            // Orchestration (1) — phase 2
            "stack",
            // Shared file systems (2) — phase 2
            "share", "share_access",
            // Placement (1)
            "placement",
            // IAD3 gap-fill (11) — phase 2
            "database_instance", "database_flavor", "database_datastore",
            "metric", "resource_type",
            "queue",
            "reservation", "allocation",
            "backup", "schedule",
            "cfn_stack",
        ]
        let actual = Set(catalog.names)
        #expect(actual == expected, "Catalog names mismatch. Missing: \(expected.subtracting(actual)). Extra: \(actual.subtracting(expected))")
        #expect(catalog.resources.count == 63, "Expected 63 resources (52 + 11 IAD3 gap-fill), got \(catalog.resources.count)")
    }

    // MARK: - Verb sets (sample covering every cell type)

    @Test("server has L/G/C/U/D")
    func serverVerbs() {
        let d = catalog.descriptor("server")!
        #expect(d.verbs == [.list, .get, .create, .update, .delete])
    }

    @Test("availability_zone has L only")
    func azVerbs() {
        let d = catalog.descriptor("availability_zone")!
        #expect(d.verbs == [.list])
    }

    @Test("compute_quota has G/U only")
    func computeQuotaVerbs() {
        let d = catalog.descriptor("compute_quota")!
        #expect(d.verbs == [.get, .update])
    }

    @Test("security_group_rule has L/G/C/D but no U")
    func sgrVerbs() {
        let d = catalog.descriptor("security_group_rule")!
        #expect(d.verbs == [.list, .get, .create, .delete])
        #expect(!d.verbs.contains(.update))
    }

    @Test("image has L/G/C/U/D")
    func imageVerbs() {
        let d = catalog.descriptor("image")!
        #expect(d.verbs == [.list, .get, .create, .update, .delete])
    }

    // MARK: - Actions (§8.6)

    @Test("server actions: destructive and adminOnly flags")
    func serverActions() {
        let actions = catalog.actions(for: "server")
        #expect(actions["rebuild"]?.destructive == true, "rebuild should be destructive")
        #expect(actions["snapshot"]?.destructive == false, "snapshot should NOT be destructive")
        #expect(actions["evacuate"]?.adminOnly == true, "evacuate should be adminOnly")
        #expect(actions["reboot"]?.destructive == true, "reboot should be destructive")
        #expect(actions["stop"]?.destructive == true, "stop should be destructive")
        #expect(actions["resize"]?.destructive == true, "resize should be destructive")
        #expect(actions["live_migrate"]?.adminOnly == true, "live_migrate should be adminOnly")
        #expect(actions["migrate"]?.adminOnly == true, "migrate should be adminOnly")
    }

    @Test("volume actions: reset_status destructive, extend/retype not")
    func volumeActions() {
        let actions = catalog.actions(for: "volume")
        #expect(actions["reset_status"]?.destructive == true, "reset_status should be destructive")
        #expect(actions["extend"]?.destructive == false, "extend should NOT be destructive")
        #expect(actions["retype"]?.destructive == false, "retype should NOT be destructive")
        #expect(actions["upload_to_image"] != nil, "upload_to_image action should exist")
        #expect(actions["set_bootable"] != nil, "set_bootable action should exist")
    }

    @Test("floating_ip actions: disassociate destructive")
    func fipActions() {
        let actions = catalog.actions(for: "floating_ip")
        #expect(actions["disassociate"]?.destructive == true, "disassociate should be destructive")
        #expect(actions["associate"]?.destructive == false, "associate should NOT be destructive")
    }

    @Test("router actions: clear_gateway destructive")
    func routerActions() {
        let actions = catalog.actions(for: "router")
        #expect(actions["clear_gateway"]?.destructive == true, "clear_gateway should be destructive")
        #expect(actions["set_gateway"]?.destructive == false, "set_gateway should NOT be destructive")
    }

    @Test("compute_service actions: disable destructive")
    func computeServiceActions() {
        let actions = catalog.actions(for: "compute_service")
        #expect(actions["disable"]?.destructive == true, "disable should be destructive")
        #expect(actions["enable"]?.destructive == false, "enable should NOT be destructive")
    }

    @Test("image actions: deactivate destructive")
    func imageActions() {
        let actions = catalog.actions(for: "image")
        #expect(actions["deactivate"]?.destructive == true, "deactivate should be destructive")
        #expect(actions["protect"]?.destructive == false, "protect should NOT be destructive")
        #expect(actions["reactivate"]?.destructive == false, "reactivate should NOT be destructive")
    }

    @Test("volume_backup actions: restore destructive")
    func backupActions() {
        let actions = catalog.actions(for: "volume_backup")
        #expect(actions["restore"]?.destructive == true, "restore should be destructive")
    }

    @Test("server action count matches spec")
    func serverActionCount() {
        let actions = catalog.actions(for: "server")
        // start, stop, reboot, pause, unpause, suspend, resume, lock, unlock,
        // shelve, unshelve, rescue, unrescue, resize, confirm_resize, revert_resize,
        // rebuild, snapshot, console_output, provisioning_status, console_url,
        // add_security_group, remove_security_group, evacuate, live_migrate, migrate
        #expect(actions.count == 26, "Expected 26 server actions, got \(actions.count)")
    }

    // MARK: - Terminal states (§8.9)

    @Test("server terminal states")
    func serverTerminalStates() {
        let d = catalog.descriptor("server")!
        #expect(Set(d.terminalStates) == ["ACTIVE", "SHUTOFF", "ERROR", "SHELVED_OFFLOADED"])
    }

    @Test("volume terminal states")
    func volumeTerminalStates() {
        let d = catalog.descriptor("volume")!
        #expect(Set(d.terminalStates) == ["available", "in-use", "error"])
    }

    @Test("image terminal states")
    func imageTerminalStates() {
        let d = catalog.descriptor("image")!
        #expect(Set(d.terminalStates) == ["active", "killed"])
    }

    @Test("router terminal states")
    func routerTerminalStates() {
        let d = catalog.descriptor("router")!
        #expect(Set(d.terminalStates) == ["ACTIVE", "DOWN"])
    }

    @Test("floating_ip terminal states")
    func fipTerminalStates() {
        let d = catalog.descriptor("floating_ip")!
        #expect(Set(d.terminalStates) == ["ACTIVE", "DOWN"])
    }

    // MARK: - Links (§8.7)

    @Test("all seven link kinds present")
    func linkKinds() {
        let links = catalog.allLinks
        let expectedKinds: Set<String> = ["volume", "interface", "security_group", "floating_ip", "router_interface", "router_gateway", "image"]
        let actualKinds = Set(links.keys)
        #expect(expectedKinds.isSubset(of: actualKinds), "Missing link kinds: \(expectedKinds.subtracting(actualKinds))")
    }

    @Test("volume link has correct source/target")
    func volumeLink() {
        let link = catalog.allLinks["volume"]!
        #expect(link.source.resource == "server")
        #expect(link.target.resource == "volume")
        #expect(link.params.contains { $0.name == "device" })
        #expect(link.params.contains { $0.name == "delete_on_termination" })
    }

    @Test("interface link has correct source/target")
    func interfaceLink() {
        let link = catalog.allLinks["interface"]!
        #expect(link.source.resource == "server")
        #expect(link.target.resource == "port")
    }

    @Test("floating_ip link has correct source/target")
    func floatingIPLink() {
        let link = catalog.allLinks["floating_ip"]!
        #expect(link.source.resource == "floating_ip")
        #expect(link.target.resource == "port")
    }

    // MARK: - Schema validation (§8.2)

    @Test("server create: missing name yields issue")
    func serverCreateMissingName() {
        let d = catalog.descriptor("server")!
        let schema = d.createSchema!
        let bad = JSONValue.object([
            "flavor": .string("m1.small"),
            "image": .string("ubuntu-24.04")
            // missing "name"
        ])
        let issues = schema.validate(bad)
        #expect(!issues.isEmpty, "Expected validation issues for missing name")
        #expect(issues.contains { $0.path == "$.name" && $0.found == "missing" }, "Expected missing name issue, got: \(issues)")
    }

    @Test("server create: wrong flavor type yields issue with path and expected")
    func serverCreateWrongFlavorType() {
        let d = catalog.descriptor("server")!
        let schema = d.createSchema!
        let bad = JSONValue.object([
            "name": .string("web-1"),
            "flavor": .integer(123),  // should be string
            "image": .string("ubuntu-24.04")
        ])
        let issues = schema.validate(bad)
        #expect(issues.contains { $0.path == "$.flavor" && $0.expected == "string" && $0.found == "integer" }, "Expected flavor type issue, got: \(issues)")
    }

    @Test("server create: valid spec yields zero issues")
    func serverCreateValid() {
        let d = catalog.descriptor("server")!
        let schema = d.createSchema!
        let good = JSONValue.object([
            "name": .string("web-1"),
            "flavor": .string("m1.small"),
            "image": .string("ubuntu-24.04"),
            "key_name": .string("my-key"),
            "availability_zone": .string("nova")
        ])
        let issues = schema.validate(good)
        #expect(issues.isEmpty, "Expected no issues for valid spec, got: \(issues)")
    }

    @Test("volume create: size required, wrong type caught")
    func volumeCreateValidation() {
        let d = catalog.descriptor("volume")!
        let schema = d.createSchema!

        // Missing size
        let missingSize = JSONValue.object(["name": .string("vol-1")])
        let issues1 = schema.validate(missingSize)
        #expect(issues1.contains { $0.path == "$.size" }, "Expected missing size issue")

        // Wrong type for size
        let wrongType = JSONValue.object(["name": .string("vol-1"), "size": .string("10")])
        let issues2 = schema.validate(wrongType)
        #expect(issues2.contains { $0.path == "$.size" && $0.expected == "integer" && $0.found == "string" }, "Expected size type issue")
    }

    // MARK: - Default list fields

    @Test("server default list fields")
    func serverDefaultFields() {
        let d = catalog.descriptor("server")!
        #expect(d.defaultListFields == ["id", "name", "status", "flavor", "addresses", "created"])
    }

    @Test("port default list fields")
    func portDefaultFields() {
        let d = catalog.descriptor("port")!
        #expect(d.defaultListFields.contains("id"))
        #expect(d.defaultListFields.contains("name"))
        #expect(d.defaultListFields.contains("status"))
        #expect(d.defaultListFields.contains("fixed_ips"))
        #expect(d.defaultListFields.contains("security_groups"))
        #expect(d.defaultListFields.contains("mac_address"))
        #expect(d.defaultListFields.contains("device_owner"))
    }

    // MARK: - Service grouping

    @Test("identity has 10 resources")
    func identityCount() {
        #expect(catalog.resources(for: .identity).count == 10, "Expected 10 identity resources, got \(catalog.resources(for: .identity).count)")
    }

    @Test("compute has 10 resources")
    func computeCount() {
        #expect(catalog.resources(for: .compute).count == 10, "Expected 10 compute resources, got \(catalog.resources(for: .compute).count)")
    }

    @Test("network has 9 resources")
    func networkCount() {
        #expect(catalog.resources(for: .network).count == 9, "Expected 9 network resources, got \(catalog.resources(for: .network).count)")
    }

    @Test("blockStorage has 5 resources")
    func blockStorageCount() {
        #expect(catalog.resources(for: .blockStorage).count == 5, "Expected 5 block storage resources, got \(catalog.resources(for: .blockStorage).count)")
    }

    @Test("image has 1 resource")
    func imageCount() {
        #expect(catalog.resources(for: .image).count == 1, "Expected 1 image resource, got \(catalog.resources(for: .image).count)")
    }

    @Test("objectStorage has 2 resources")
    func objectStorageCount() {
        #expect(catalog.resources(for: .objectStorage).count == 2, "Expected 2 object-storage resources, got \(catalog.resources(for: .objectStorage).count)")
    }

    @Test("keyManager has 2 resources")
    func keyManagerCount() {
        #expect(catalog.resources(for: .keyManager).count == 2, "Expected 2 key-manager resources, got \(catalog.resources(for: .keyManager).count)")
    }

    @Test("secret is pollable (status lifecycle) and has get_payload action")
    func secretDescriptor() {
        let d = catalog.descriptor("secret")!
        #expect(d.service == .keyManager)
        #expect(d.statusField == "status")
        #expect(d.terminalStates.contains("active"))
        #expect(d.actions.contains { $0.name == "get_payload" })
        let sc = catalog.descriptor("secret_container")!
        #expect(sc.service == .keyManager)
        #expect(sc.statusField == nil)
    }

    @Test("loadBalancer has 5 resources and load_balancer is pollable")
    func loadBalancerCount() {
        #expect(catalog.resources(for: .loadBalancer).count == 5, "Expected 5 load-balancer resources, got \(catalog.resources(for: .loadBalancer).count)")
        let d = catalog.descriptor("load_balancer")!
        #expect(d.service == .loadBalancer)
        #expect(d.statusField == "provisioning_status")
        #expect(d.terminalStates.contains("ACTIVE"))
    }

    @Test("dns has 2 resources and zone is pollable")
    func dnsCount() {
        #expect(catalog.resources(for: .dns).count == 2, "Expected 2 dns resources, got \(catalog.resources(for: .dns).count)")
        let d = catalog.descriptor("zone")!
        #expect(d.service == .dns)
        #expect(d.statusField == "status")
        #expect(d.terminalStates.contains("active"))
    }

    @Test("containerInfra has 2 resources and cluster is pollable")
    func containerInfraCount() {
        #expect(catalog.resources(for: .containerInfra).count == 2, "Expected 2 container resources, got \(catalog.resources(for: .containerInfra).count)")
        let d = catalog.descriptor("cluster")!
        #expect(d.service == .containerInfra)
        #expect(d.statusField == "status")
        #expect(d.terminalStates.contains("ACTIVE"))
    }

    @Test("orchestration has 1 resource and stack is pollable with get_outputs action")
    func orchestrationCount() {
        #expect(catalog.resources(for: .orchestration).count == 1, "Expected 1 orchestration resource, got \(catalog.resources(for: .orchestration).count)")
        let d = catalog.descriptor("stack")!
        #expect(d.service == .orchestration)
        #expect(d.statusField == "status")
        #expect(d.terminalStates.contains("CREATE_COMPLETE"))
        #expect(d.actions.contains { $0.name == "get_outputs" })
    }

    @Test("sharev2 has 2 resources and share is pollable")
    func sharev2Count() {
        #expect(catalog.resources(for: .sharev2).count == 2, "Expected 2 share resources, got \(catalog.resources(for: .sharev2).count)")
        let d = catalog.descriptor("share")!
        #expect(d.service == .sharev2)
        #expect(d.statusField == "status")
        #expect(d.terminalStates.contains("available"))
    }

    @Test("container + object descriptors are well-formed")
    func objectStorageDescriptors() {
        let ctn = catalog.descriptor("container")!
        #expect(ctn.service == .objectStorage)
        #expect(ctn.verbs.contains(.list) && ctn.verbs.contains(.create) && ctn.verbs.contains(.delete))
        #expect(!ctn.verbs.contains(.update))
        let obj = catalog.descriptor("object")!
        #expect(obj.service == .objectStorage)
        #expect(obj.createSchema != nil)
        #expect(obj.listFilters.contains("container"))
    }

    // MARK: - IAD3 gap-fill services (phase 2)

    @Test("database has 3 resources and database_instance is pollable + creatable")
    func databaseCount() {
        #expect(catalog.resources(for: .database).count == 3)
        let d = catalog.descriptor("database_instance")!
        #expect(d.service == .database)
        #expect(d.statusField == "status")
        #expect(d.terminalStates.contains("ACTIVE"))
        #expect(d.verbs.contains(.create) && d.verbs.contains(.delete))
        #expect(d.createSchema != nil)
    }

    @Test("metric has 2 resources")
    func metricCount() {
        #expect(catalog.resources(for: .metric).count == 2)
        #expect(catalog.descriptor("metric")!.service == .metric)
        #expect(catalog.descriptor("resource_type")!.service == .metric)
        // read-only: no create/update/delete
        let m = catalog.descriptor("metric")!
        #expect(!m.verbs.contains(.create) && !m.verbs.contains(.delete))
    }

    @Test("messaging has 1 read-only queue resource keyed by name")
    func messagingCount() {
        #expect(catalog.resources(for: .messaging).count == 1)
        let q = catalog.descriptor("queue")!
        #expect(q.service == .messaging)
        #expect(q.idField == "name")
        #expect(!q.verbs.contains(.create))
    }

    @Test("reservation has 2 resources and reservation is pollable + creatable")
    func reservationCount() {
        #expect(catalog.resources(for: .reservation).count == 2)
        let r = catalog.descriptor("reservation")!
        #expect(r.service == .reservation)
        #expect(r.statusField == "status")
        #expect(r.terminalStates.contains("ACTIVE"))
        #expect(r.verbs.contains(.create) && r.verbs.contains(.delete))
    }

    @Test("backup has 2 read-only resources")
    func backupCount() {
        #expect(catalog.resources(for: .backup).count == 2)
        #expect(catalog.descriptor("backup")!.service == .backup)
        #expect(catalog.descriptor("schedule")!.service == .backup)
    }

    @Test("cloudformation cfn_stack is registered but phase-1 (501 by design)")
    func cloudFormationCount() {
        #expect(catalog.resources(for: .cloudformation).count == 1)
        let c = catalog.descriptor("cfn_stack")!
        #expect(c.service == .cloudformation)
        #expect(c.phase1Note != nil)
    }
}
