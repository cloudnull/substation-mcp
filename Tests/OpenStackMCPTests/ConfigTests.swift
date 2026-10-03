import Testing
import Foundation
import OpenStackMCPServer
@testable import substation_mcp

// MARK: - Config precedence (spec §11.1: CLI > env > YAML > defaults)

@Test("default config has the Global-Constraints values")
func defaults() {
    let d = OpenStackMCPConfig()
    #expect(d.serverHost == "127.0.0.1")
    #expect(d.serverPort == 8080)
    #expect(d.serverEndpoint == "/v1")
    #expect(d.logLevel == "info")
    #expect(d.logFormat == "json")
    #expect(d.logAudit == true)
    #expect(d.serverMetricsToken == nil)
}

@Test("YAML-only values are applied over defaults")
func yamlBeatsDefaults() {
    let cfg = ConfigLoader.read(ConfigLoader.resolve(
        cli: [:],
        env: [:],
        yaml: ["server__port": "9090", "log__level": "debug"]
    ))
    #expect(cfg.serverPort == 9090)
    #expect(cfg.logLevel == "debug")
}

@Test("env beats YAML")
func envBeatsYaml() {
    let cfg = ConfigLoader.read(ConfigLoader.resolve(
        cli: [:],
        env: ["OSMCP_SERVER__PORT": "9191"],
        yaml: ["server__port": "9090"]
    ))
    #expect(cfg.serverPort == 9191)
}

@Test("CLI beats env beats YAML")
func cliBeatsEnvBeatsYaml() {
    // All three set the port; CLI must win.
    let cfg = ConfigLoader.read(ConfigLoader.resolve(
        cli: ["port": "9292"],
        env: ["OSMCP_SERVER__PORT": "9191"],
        yaml: ["server__port": "9090"]
    ))
    #expect(cfg.serverPort == 9292)
}

@Test("a CLI flag and env set for different keys both apply")
func independentKeysCoexist() {
    let cfg = ConfigLoader.read(ConfigLoader.resolve(
        cli: ["host": "0.0.0.0"],
        env: ["OSMCP_SERVER__PORT": "9191"],
        yaml: ["log__level": "debug"]
    ))
    #expect(cfg.serverHost == "0.0.0.0")   // from CLI
    #expect(cfg.serverPort == 9191)        // from env
    #expect(cfg.logLevel == "debug")       // from YAML
}

@Test("CLI flag names map to spec key paths")
func cliFlagNamesMapToSpecKeys() {
    let cfg = ConfigLoader.read(ConfigLoader.resolve(
        cli: ["port": "7777", "logLevel": "debug", "readOnly": "true"],
        env: [:],
        yaml: [:]
    ))
    #expect(cfg.serverPort == 7777)        // port -> server__port
    #expect(cfg.logLevel == "debug")       // logLevel -> log__level
    #expect(cfg.policyReadOnly == true)    // readOnly -> policy__read_only
}

@Test("sectioned CLI flag names map to spec key paths")
func sectionedCliFlagNamesMap() {
    let cfg = ConfigLoader.read(ConfigLoader.resolve(
        cli: ["serverMaxBodyBytes": "4194304", "authProfile": "oauth"],
        env: [:],
        yaml: [:]
    ))
    #expect(cfg.serverMaxBodyBytes == 4_194_304)  // serverMaxBodyBytes -> server__max_body_bytes
    #expect(cfg.authProfile == "oauth")            // authProfile -> auth__profile
}

@Test("environment OSMCP prefix with double-underscore separator")
func envPrefixSeparator() {
    let resolved = ConfigLoader.resolve(
        cli: [:],
        env: [
            "OSMCP_AUTH__PROFILE": "oauth",
            "OSMCP_LOG__AUDIT": "false",
            "OSMCP_UNRELATED": "ignored"
        ],
        yaml: [:]
    )
    let cfg = ConfigLoader.read(resolved)
    #expect(cfg.authProfile == "oauth")
    #expect(cfg.logAudit == false)
    // An unrelated OSMCP_ key is stripped to a no-op key path (not used by
    // `read`); it must not affect any real config field.
    #expect(resolved["unrelated"] == "ignored")
    #expect(cfg.serverPort == 8080) // untouched default
}

@Test("YAML array values flatten to comma-joined strings")
func yamlArrayFlattens() {
    let resolved = ConfigLoader.resolve(
        cli: [:],
        env: [:],
        yaml: ["policy__deny_resources": "project,user,role"]
    )
    let cfg = ConfigLoader.read(resolved)
    #expect(cfg.policyDenyResources == ["project", "user", "role"])
}

@Test("log.audit is configurable and defaults true")
func logAuditConfig() {
    #expect(OpenStackMCPConfig().logAudit == true)
    let resolved = ConfigLoader.resolve(cli: [:], env: [:], yaml: ["log__audit": "false"])
    #expect(ConfigLoader.read(resolved).logAudit == false)
}

@Test("metrics token is optional")
func metricsTokenOptional() {
    #expect(OpenStackMCPConfig().serverMetricsToken == nil)
    let resolved = ConfigLoader.resolve(
        cli: [:], env: [:], yaml: ["server__metrics_token": "sekrit"]
    )
    #expect(ConfigLoader.read(resolved).serverMetricsToken == "sekrit")
}
