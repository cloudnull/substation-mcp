import Testing
import Foundation
import Provisioning

@Suite("Distro detection")
struct DistroTests {
    @Test("detect by explicit os_distro property")
    func byProperty() {
        #expect(Distro.detect(name: nil, tags: nil, properties: ["os_distro": "centos"]) == .centos)
        #expect(Distro.detect(name: nil, tags: nil, properties: ["os_type": "Rocky"]) == .rocky)
    }

    @Test("os_distro wins over os_type")
    func distroPriority() {
        let d = Distro.detect(name: nil, tags: nil, properties: ["os_distro": "ubuntu", "os_type": "rhel"])
        #expect(d == .ubuntu)
    }

    @Test("detect by Glance tag")
    func byTag() {
        #expect(Distro.detect(name: nil, tags: ["fedora", "minimal"], properties: nil) == .fedora)
        #expect(Distro.detect(name: nil, tags: ["ALMA-9"], properties: nil) == .alma)
    }

    @Test("detect by image name (substring, case-insensitive)")
    func byName() {
        #expect(Distro.detect(name: "Ubuntu-24.04-live", tags: nil, properties: nil) == .ubuntu)
        #expect(Distro.detect(name: "RedHat-9-GA", tags: nil, properties: nil) == .rhel)
        #expect(Distro.detect(name: "almalinux-8.10.qcow2", tags: nil, properties: nil) == .alma)
    }

    @Test("specific name matches before generic (debian tag on ubuntu image)")
    func specificity() {
        // The table checks "ubuntu" before "debian", so a name containing both
        // resolves to ubuntu.
        #expect(Distro.detect(name: "ubuntu-debian-compat", tags: nil, properties: nil) == .ubuntu)
        #expect(Distro.detect(name: "debian-12", tags: nil, properties: nil) == .debian)
    }

    @Test("family mapping")
    func families() {
        #expect(Distro.ubuntu.family == .apt)
        #expect(Distro.debian.family == .apt)
        #expect(Distro.fedora.family == .yum)
        #expect(Distro.rhel.family == .yum)
        #expect(Distro.rocky.family == .yum)
    }

    @Test("unknown fallback")
    func unknown() {
        #expect(Distro.detect(name: "windows-2022", tags: nil, properties: nil) == .unknown)
        #expect(Distro.detect(name: nil, tags: nil, properties: nil) == .unknown)
        #expect(Distro.unknown.family == .unknown)
    }
}

@Suite("CloudInit rendering")
struct RendererTests {
    // MARK: - Determinism

    @Test("render is deterministic (same spec+distro -> identical bytes)")
    func deterministic() throws {
        let spec = ProvisioningSpec(packages: ["curl", "vim"], services: ["curl"],
                                    users: [.init(name: "bob", sudo: true)],
                                    firewall: [.init(proto: "tcp", port: 8080)],
                                    finalMessage: "hi")
        let a = try CloudInitRenderer.render(spec: spec, distro: .ubuntu)
        let b = try CloudInitRenderer.render(spec: spec, distro: .ubuntu)
        #expect(a == b)
        #expect(a.hasPrefix("#cloud-config"))
    }

    @Test("sha is stable and 8 hex chars")
    func shaStable() {
        let spec = ProvisioningSpec(packages: ["curl"])
        #expect(spec.sha == ProvisioningSpec.sha(for: spec))
        #expect(spec.sha.count == 8)
        #expect(spec.sha.allSatisfy { $0.isHexDigit })
        // Different spec -> different sha.
        let other = ProvisioningSpec(packages: ["vim"])
        #expect(spec.sha != other.sha)
    }

    @Test("different distro changes render (apt vs yum)")
    func aptVsYum() throws {
        let spec = ProvisioningSpec(packages: ["curl"])
        let apt = try CloudInitRenderer.render(spec: spec, distro: .ubuntu)
        let yum = try CloudInitRenderer.render(spec: spec, distro: .fedora)
        #expect(apt.contains("apt-get install -y 'curl'"))
        #expect(apt.contains("DEBIAN_FRONTEND=noninteractive"))
        #expect(yum.contains("dnf install -y 'curl'"))
        #expect(!yum.contains("apt-get"))
        #expect(apt != yum)
    }

    @Test("unknown distro emits safe no-op (no install command)")
    func unknownNoop() throws {
        let spec = ProvisioningSpec(packages: ["curl"], firewall: [.init(proto: "tcp", port: 22)])
        let out = try CloudInitRenderer.render(spec: spec, distro: .unknown)
        #expect(!out.contains("apt-get install"))
        #expect(!out.contains("dnf install"))
        #expect(out.contains("WARN: unknown distro"))
        #expect(out.contains("skipping package install"))
        // Markers still present.
        #expect(out.contains("OSMCP_PROVISION_BEGIN"))
        #expect(out.contains("OSMCP_PROVISION_END"))
    }

    // MARK: - Shell escaping

    @Test("shell quoting protects single quotes in package/service names")
    func shellQuoting() throws {
        let spec = ProvisioningSpec(packages: ["it's-a-pkg"], services: ["we'ird"])
        let out = try CloudInitRenderer.render(spec: spec, distro: .ubuntu)
        // 'it's-a-pkg' -> 'it'\''s-a-pkg'
        #expect(out.contains("'it'\\''s-a-pkg'"))
        #expect(out.contains("systemctl enable 'we'\\''ird'"))
    }

    // MARK: - Users

    @Test("users are rendered via the native users: section, sorted by name")
    func users() throws {
        let spec = ProvisioningSpec(users: [
            .init(name: "zoe", shell: "/bin/zsh"),
            .init(name: "amy", sudo: true),
        ])
        let out = try CloudInitRenderer.render(spec: spec, distro: .debian)
        #expect(out.contains("users:"))
        // Sorted: amy before zoe.
        #expect(out.range(of: "- name: amy")!.lowerBound < out.range(of: "- name: zoe")!.lowerBound)
        #expect(out.contains("shell: /bin/bash")) // amy default
        #expect(out.contains("shell: /bin/zsh"))
        #expect(out.contains("sudo: 'ALL=(ALL) NOPASSWD:ALL'"))
        #expect(out.contains("groups: sudo,wheel"))
    }

    // MARK: - Firewall

    @Test("firewall renders ufw on apt")
    func firewallApt() throws {
        let spec = ProvisioningSpec(firewall: [.init(proto: "tcp", port: 8080)])
        let out = try CloudInitRenderer.render(spec: spec, distro: .ubuntu)
        #expect(out.contains("ufw --force enable"))
        #expect(out.contains("ufw allow 'tcp/8080'"))
    }

    @Test("firewall renders firewalld on yum")
    func firewallYum() throws {
        let spec = ProvisioningSpec(firewall: [.init(proto: "tcp", port: 8080)])
        let out = try CloudInitRenderer.render(spec: spec, distro: .centos)
        #expect(out.contains("firewalld"))
        #expect(out.contains("firewall-cmd --permanent --add-port='8080':'tcp'"))
    }

    // MARK: - finalMessage / write_files

    @Test("finalMessage writes /etc/motd.d/99-osmcp")
    func motd() throws {
        let spec = ProvisioningSpec(packages: ["curl"], finalMessage: "Provisioned\nby osmcp")
        let out = try CloudInitRenderer.render(spec: spec, distro: .ubuntu)
        #expect(out.contains("write_files:"))
        #expect(out.contains("path: /etc/motd.d/99-osmcp"))
        #expect(out.contains("Provisioned"))
        #expect(out.contains("by osmcp"))
        #expect(out.contains("owner: root:root"))
        #expect(out.contains("permissions: '0644'"))
    }

    // MARK: - Markers

    @Test("BEGIN/END markers carry the spec sha")
    func markers() throws {
        let spec = ProvisioningSpec(packages: ["curl"])
        let out = try CloudInitRenderer.render(spec: spec, distro: .ubuntu)
        #expect(out.contains("OSMCP_PROVISION_BEGIN \(spec.sha)"))
        #expect(out.contains("OSMCP_PROVISION_END \(spec.sha) ok=$OSMCP_OK"))
    }

    // MARK: - Rejections

    @Test("empty spec is rejected")
    func emptyRejected() {
        let spec = ProvisioningSpec()
        #expect(spec.isEmpty)
        do {
            _ = try CloudInitRenderer.render(spec: spec, distro: .ubuntu)
            Issue.record("expected emptySpec")
        } catch let e as CloudInitRenderer.RenderError {
            #expect(e.kind == .emptySpec)
            #expect(e.partial == nil)
        } catch let e {
            Issue.record("wrong error type \(e)")
        }
    }

    @Test("oversized render is rejected with partial yaml")
    func oversized() {
        // Push the plaintext over the 12 KiB cap with many package names.
        var pkgs: [String] = []
        for i in 0..<400 { pkgs.append("pkg-\(String(repeating: "x", count: 20))-\(i)") }
        let spec = ProvisioningSpec(packages: pkgs)
        do {
            _ = try CloudInitRenderer.render(spec: spec, distro: .ubuntu)
            Issue.record("expected oversized")
        } catch let e as CloudInitRenderer.RenderError {
            #expect(e.kind == .oversized(size: e.partial!.utf8.count, limit: CloudInitRenderer.maxSize))
            #expect(e.partial != nil)
        } catch let e {
            Issue.record("wrong error type \(e)")
        }
    }

    @Test("base64 render decodes back to the plaintext")
    func base64RoundTrip() throws {
        let spec = ProvisioningSpec(packages: ["curl"])
        let b64 = try CloudInitRenderer.renderBase64(spec: spec, distro: .ubuntu)
        let decoded = String(data: Data(base64Encoded: b64)!, encoding: .utf8)!
        let plain = try CloudInitRenderer.render(spec: spec, distro: .ubuntu)
        #expect(decoded == plain)
    }

    // MARK: - from(dict:) decoding

    @Test("from(dict:) parses a full spec")
    func fromDict() throws {
        let dict: [String: Any] = [
            "packages": ["curl", "vim"],
            "services": ["curl"],
            "users": [["name": "bob", "shell": "/bin/zsh", "sudo": true]],
            "firewall": [["proto": "tcp", "port": 8080]],
            "extra_runcmd": ["echo hi"],
            "final_message": "done",
        ]
        let spec = try ProvisioningSpec.from(dict: dict)
        #expect(spec.packages == ["curl", "vim"])
        #expect(spec.services == ["curl"])
        #expect(spec.users == [.init(name: "bob", shell: "/bin/zsh", sudo: true)])
        #expect(spec.firewall == [.init(proto: "tcp", port: 8080)])
        #expect(spec.extraRuncmd == ["echo hi"])
        #expect(spec.finalMessage == "done")
        #expect(!spec.isEmpty)
    }

    @Test("from(dict:) empty dict yields empty spec")
    func fromDictEmpty() throws {
        let spec = try ProvisioningSpec.from(dict: [:])
        #expect(spec.isEmpty)
    }

    @Test("from(dict:) rejects wrong type")
    func fromDictBadType() {
        do {
            _ = try ProvisioningSpec.from(dict: ["packages": "curl"])
            Issue.record("expected wrongType")
        } catch let e as RenderDecodingError {
            #expect(e == .wrongType("[string]", path: "packages"))
        } catch let e {
            Issue.record("wrong error \(e)")
        }
    }

    @Test("from(dict:) rejects missing user name")
    func fromDictMissingName() {
        do {
            _ = try ProvisioningSpec.from(dict: ["users": [["shell": "/bin/bash"]]])
            Issue.record("expected missingField")
        } catch let e as RenderDecodingError {
            #expect(e == .missingField("users[0].name"))
        } catch let e {
            Issue.record("wrong error \(e)")
        }
    }
}

@Suite("CloudInit parsing")
struct ParserTests {
    let sha = "abcd1234"

    @Test("no markers -> unknown")
    func unknown() {
        let r = CloudInitParser.parse("[    1.0] boot\nLogin ready.\n")
        #expect(r.status == .unknown)
        #expect(r.sha == nil)
        #expect(!r.started)
    }

    @Test("BEGIN only -> pending")
    func pending() {
        let r = CloudInitParser.parse("[ 12.0] OSMCP_PROVISION_BEGIN \(sha)\n")
        #expect(r.status == .pending)
        #expect(r.started)
        #expect(!r.finished)
        #expect(r.sha == sha)
    }

    @Test("BEGIN + END ok=1 -> succeeded")
    func succeeded() {
        let console = """
        [ 12.0] OSMCP_PROVISION_BEGIN \(sha)
        [ 12.1] [osmcp-provision] apt-get install -y curl -> rc=0
        [ 15.0] OSMCP_PROVISION_END \(sha) ok=1
        """
        let r = CloudInitParser.parse(console)
        #expect(r.status == .succeeded)
        #expect(r.finished)
        #expect(r.sha == sha)
    }

    @Test("BEGIN + END ok=0 -> failed")
    func failed() {
        let console = """
        [ 12.0] OSMCP_PROVISION_BEGIN \(sha)
        [ 15.0] OSMCP_PROVISION_END \(sha) ok=0
        """
        let r = CloudInitParser.parse(console)
        #expect(r.status == .failed)
        #expect(!r.finished)
        #expect(r.started)
    }

    @Test("sha mismatch with expected -> unknown")
    func shaMismatch() {
        let r = CloudInitParser.parse("OSMCP_PROVISION_END \(sha) ok=1\n", expectedSha: "ffff9999")
        #expect(r.status == .unknown)
        #expect(r.sha == sha)
        #expect(r.detail?.contains("does not match") == true)
    }

    @Test("matching expected sha -> succeeded")
    func expectedMatch() {
        let r = CloudInitParser.parse("OSMCP_PROVISION_BEGIN \(sha)\nOSMCP_PROVISION_END \(sha) ok=1\n", expectedSha: sha)
        #expect(r.status == .succeeded)
    }

    @Test("status only ever moves forward (idempotent on longer console)")
    func monotonic() {
        let begin = "OSMCP_PROVISION_BEGIN \(sha)\n"
        let full = begin + "OSMCP_PROVISION_END \(sha) ok=1\n"
        #expect(CloudInitParser.parse(begin).status == .pending)
        #expect(CloudInitParser.parse(full).status == .succeeded)
    }
}

