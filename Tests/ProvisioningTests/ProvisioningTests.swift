import Testing
import Foundation
import Provisioning
import Yams

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
        // 'it's-a-pkg' -> shell-quoted 'it'\''s-a-pkg' (the canonical POSIX
        // '\'' close-escape-reopen form). That line is then emitted inside a
        // DOUBLE-QUOTED YAML flow scalar, where every backslash must be doubled
        // to \\ so cloud-init decodes it back to the intended single '\'. So the
        // bytes actually present in the rendered text carry TWO backslashes:
        // 'it'\\''s-a-pkg'. After YAML unescaping, sh sees 'it'\''s-a-pkg' —
        // the correct quoted argument.
        #expect(out.contains("'it'\\\\''s-a-pkg'"), "package should be shell-quoted then YAML-doubled; got:\n\(out)")
        #expect(out.contains("systemctl enable 'we'\\\\''ird'"), "service should be shell-quoted then YAML-doubled; got:\n\(out)")
    }


    // MARK: - YAML validity (regression: nested single quotes broke cloud-init)

    @Test("extra_runcmd with shell-quoted args renders valid YAML")
    func extraRuncmdYAMLValid() throws {
        // Each runcmd entry is a plain double-quoted YAML string (not [sh, -c, ...]).
        // cloud-init's shellify writes them as direct lines in one /bin/sh script,
        // so provision_one() and PROVISION_RC persist across lines.
        let spec = ProvisioningSpec(extraRuncmd: [
            "dnf install -y epel-release",
            "dnf upgrade --security -y",
            "dnf install -y podman podman-compose",
            "dnf clean all",
        ])
        let out = try CloudInitRenderer.render(spec: spec, distro: .rocky)
        // Every extra_runcmd line appears as a plain double-quoted YAML scalar.
        for cmd in spec.extraRuncmd {
            let needle = "- \"provision_one sh -c '\(cmd)'\""
            #expect(out.contains(needle), "missing runcmd line for: \(cmd)\n---\n\(out)")
        }
        // No [sh, -c, ...] flow sequences remain.
        let runcmdBlock = out.components(separatedBy: "runcmd:").last!
        #expect(!runcmdBlock.contains("[ sh, -c,"), "runcmd still uses [sh, -c, ...] form:\n\(runcmdBlock)")
    }

    @Test("runcmd entries are plain double-quoted strings")
    func runcmdPlainStrings() throws {
        let spec = ProvisioningSpec(packages: ["curl"])
        let out = try CloudInitRenderer.render(spec: spec, distro: .ubuntu)
        // BEGIN marker is a plain double-quoted string.
        #expect(out.contains("- \"echo OSMCP_PROVISION_BEGIN \(spec.sha)\""))
        // Package install is a plain double-quoted string with shell-quoted pkg.
        #expect(out.contains("- \"provision_one env DEBIAN_FRONTEND=noninteractive apt-get install -y 'curl'\""))
        // No [sh, -c, ...] anywhere.
        #expect(!out.contains("[ sh, -c,"))
    }

    @Test("rendered cloud-init parses as valid YAML with plain string runcmd")
    func rendersValidYAML() throws {
        let spec = ProvisioningSpec(
            packages: ["podman", "podman-compose"],
            services: ["podman"],
            users: [.init(name: "deployer", sudo: true)],
            firewall: [.init(proto: "tcp", port: 8443)],
            extraRuncmd: [
                "dnf install -y epel-release",
                "dnf upgrade --security -y",
                "echo 'hello world' && echo \"double quoted\"",
            ],
            finalMessage: "provisioned\nby osmcp"
        )
        for distro in [Distro.ubuntu, Distro.debian, Distro.rocky, Distro.rhel, Distro.fedora, Distro.centos, Distro.alma, Distro.unknown] {
            let out = try CloudInitRenderer.render(spec: spec, distro: distro)
            guard let doc = try load(yaml: out) as? [String: Any] else {
                Issue.record("\(distro): rendered cloud-init is not a YAML mapping:\n\(out)")
                continue
            }
            #expect(doc["runcmd"] != nil, "\(distro): missing runcmd key")
            let cmds = doc["runcmd"] as? [String]
            #expect(cmds != nil, "\(distro): runcmd is not an array of strings")
            #expect(!cmds!.isEmpty, "\(distro): runcmd empty")
            // Each entry is a plain shell command string (no [sh, -c, ...] wrapper).
            for cmd in cmds! {
                #expect(!cmd.hasPrefix("sh"), "\(distro): unexpected sh prefix: \(cmd)")
            }
        }
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
        // ufw requires "<port>/<proto>" (port FIRST); "tcp/8080" fails with "Bad port".
        #expect(out.contains("ufw allow '8080'/'tcp'"))
        #expect(!out.contains("'tcp/8080'"))
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

