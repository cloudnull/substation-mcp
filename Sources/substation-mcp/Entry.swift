import ArgumentParser

// MARK: - Explicit CLI entry point (spec §11.3)
//
// The CLI command types (OpenStackMCP and its subcommands) are declared in
// `main.swift`. Because that file is a top-level-code file, Swift does NOT
// synthesize an `@main` for the `AsyncParsableCommand` root — and there is no
// top-level statement calling `.main()`. Without an explicit entry, the
// executable's real entry point is empty: it exits 0 immediately and prints
// nothing for EVERY subcommand (even a bad one).
//
// This file is deliberately NOT named `main.swift`, so the `@main` attribute
// below is the program's entry point and ArgumentParser dispatches to
// `OpenStackMCP` (and its subcommands) correctly.
@main
struct OpenStackMCPEntry {
    static func main() async throws {
        try await OpenStackMCP.main()
    }
}
