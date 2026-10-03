import Testing
import Foundation

// MARK: - CLI entry-point smoke (spec §11.3)
//
// The CLI types live in `Sources/substation-mcp/main.swift`. Because that file
// is a top-level-code file named `main.swift`, Swift does NOT synthesize an
// `@main` for the `AsyncParsableCommand` root, and there is no top-level
// statement calling `.main()`. The result: the executable's real entry point
// does nothing and exits 0 with no output for EVERY subcommand.
//
// Every other test in the package exercises the library (ToolListFormatter,
// ConfigLoader, ...) directly and never the process entry — so this regression
// was invisible to the suite. This test runs the actual built binary and asserts
// the entry point produces output. It self-skips when the binary is not present
// (e.g. a test run without a prior build), so CI stays green, but whenever the
// binary exists the entry is proven to work.

@Suite("CLI entry point (process smoke)", .timeLimit(.minutes(3)))
struct CLIEntryTests {

    /// Locate the built executable relative to the test process, or nil.
    private func binaryPath() -> URL? {
        // SwiftPM places executables in .build/<config>/<triple>/ next to the
        // test bundles. The exact triple dir varies; search the usual roots.
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var candidates = [
            home.appendingPathComponent(".build/release/substation-mcp"),
            home.appendingPathComponent(".build/debug/substation-mcp"),
        ]
        // Also probe /work (Apple Container mount) and CWD.
        for base in ["/work", fm.currentDirectoryPath] {
            for cfg in ["release", "debug"] {
                candidates.append(URL(fileURLWithPath: "\(base)/.build/\(cfg)/substation-mcp"))
            }
        }
        // Prefer the most-recently-built executable, so a stale binary from an
        // earlier build (which could still exhibit an entry-point regression)
        // does not shadow the current one.
        let existing = candidates.compactMap { c -> (URL, Date)? in
            guard fm.isExecutableFile(atPath: c.path),
                  let m = try? fm.attributesOfItem(atPath: c.path)[.modificationDate] as? Date
            else { return nil }
            return (c, m)
        }
        return existing.max { $0.1 < $1.1 }?.0
    }

    private func run(_ args: [String], _ bin: URL) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    @Test("binary entry point runs a subcommand and produces output")
    func entryPointProducesOutput() throws {
        guard let bin = binaryPath() else {
            print("SKIP: no built substation-mcp binary found — CLI entry smoke not run")
            return
        }
        // `tools --json` must print the 15-tool JSON array. This proves the
        // process entry point is actually wired (it exits 0 and prints nothing
        // when the entry is missing — the regression this test guards).
        let r = try run(["tools", "--json"], bin)
        #expect(r.status == 0, "tools --json exited \(r.status); stderr: \(r.err)")
        #expect(!r.out.trimmingCharacters(in: .whitespaces).isEmpty,
                "CLI entry produced no stdout (missing entry point?). stderr: \(r.err)")
        #expect(r.out.contains("os_list"), "tools output missing os_list: \(r.out.prefix(200))")
    }

    @Test("no subcommand prints usage, not silence")
    func noArgPrintsUsage() throws {
        guard let bin = binaryPath() else {
            print("SKIP: no built substation-mcp binary found — CLI entry smoke not run")
            return
        }
        let r = try run([], bin)
        // ArgumentParser prints the root usage (to stderr) and exits non-zero
        // when no subcommand is given. The regression made this exit 0 silently.
        let combined = r.out + r.err
        #expect(!combined.trimmingCharacters(in: .whitespaces).isEmpty,
                "no-arg invocation produced no usage output (missing entry point?)")
    }
}
