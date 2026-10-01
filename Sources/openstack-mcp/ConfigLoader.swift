import Foundation
import OpenStackMCPServer
import Yams

// MARK: - Config loader (spec §11.1, §11.2)

/// Loads an `OpenStackMCPConfig` from, in priority order:
///   1. command-line flags (passed via `args`),
///   2. the environment (`OSMCP_` prefix, `__` separator),
///   3. a YAML file (`--config`, default `/etc/openstack-mcp/config.yaml`),
///   4. defaults.
///
/// The YAML file is a nested map with the same key paths as the spec §11.2
/// table (e.g. `server.port`, `auth.profile`). It is parsed with Yams and
/// flattened to `__`-separated keys, then the same precedence rules apply.
public enum ConfigLoader {
    /// `args` maps the CLI flag names we already parsed (e.g. "host", "port")
    /// to their values; missing/nil values are skipped.
    public static func load(args: [String: String?]) -> OpenStackMCPConfig {
        // Precedence: CLI > env > YAML > defaults.
        let configPath: String
        if let c = args["config"], let cc = c {
            configPath = cc
        } else {
            configPath = ProcessInfo.processInfo.environment["OSMCP__CONFIG"]
                ?? "/etc/openstack-mcp/config.yaml"
        }
        let yaml = yamlValues(at: configPath)
        let env = ProcessInfo.processInfo.environment
        var cli: [String: String] = [:]
        for (flag, val) in args {
            if let val { cli[flag] = val }
        }
        return read(resolve(cli: cli, env: env, yaml: yaml))
    }

    /// Pure precedence resolution, independent of the process environment and
    /// the filesystem, so it can be unit-tested deterministically.
    ///
    /// - Parameters:
    ///   - cli: command-line flag values (highest priority), keyed by the
    ///     camelCase flag names.
    ///   - env: the raw environment (values whose key starts with `OSMCP_`
    ///     contribute; `__` is the separator), medium priority.
    ///   - yaml: flattened `__`-separated values from the config file
    ///     (lowest priority).
    ///
    /// Returns the resolved key/value map, highest priority first: a key
    /// present in `cli` wins over `env`, which wins over `yaml`.
    static func resolve(cli: [String: String], env: [String: String], yaml: [String: String]) -> [String: String] {
        var values: [String: String] = [:]
        // Lowest priority first; later writes win.
        for (k, v) in yaml { values[k] = v }
        for (key, val) in env {
            if key.hasPrefix("OSMCP_") {
                let trimmed = String(key.dropFirst("OSMCP_".count))
                let stripped = trimmed.hasPrefix("__") ? String(trimmed.dropFirst(2)) : trimmed
                values[stripped.lowercased()] = val
            }
        }
        for (flag, val) in cli {
            values[camelToDoubleUnderscore(flag)] = val
        }
        return values
    }

    static func read(_ v: [String: String]) -> OpenStackMCPConfig {
        func str(_ k: String) -> String? { v[k] }
        func int(_ k: String) -> Int? { Int(v[k] ?? "") }
        func bool(_ k: String) -> Bool? {
            switch (v[k] ?? "").lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        func arr(_ k: String) -> [String]? {
            guard let raw = v[k] else { return nil }
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        var cfg = OpenStackMCPConfig()
        // server
        cfg.serverHost = str("server__host") ?? cfg.serverHost
        cfg.serverPort = int("server__port") ?? cfg.serverPort
        cfg.serverEndpoint = str("server__endpoint") ?? cfg.serverEndpoint
        if let a = arr("server__allowed_origins") { cfg.serverAllowedOrigins = a }
        cfg.serverMaxBodyBytes = int("server__max_body_bytes") ?? cfg.serverMaxBodyBytes
        cfg.serverMetricsToken = str("server__metrics_token")
        cfg.serverPublicURL = str("server__public_url")
        cfg.serverTLSCert = str("server__tls__cert")
        cfg.serverTLSKey = str("server__tls__key")
        // auth
        cfg.authProfile = str("auth__profile") ?? cfg.authProfile
        cfg.authKeystoneURL = str("auth__keystone_url")
        cfg.authTokenCacheTTL = int("auth__token_cache_ttl") ?? cfg.authTokenCacheTTL
        cfg.authFailedAuthPerMinute = int("auth__failed_auth_per_minute") ?? cfg.authFailedAuthPerMinute
        if let b = bool("auth__login_page_enabled") { cfg.authLoginPageEnabled = b }
        // clouds
        cfg.cloudsDefault = str("clouds__default")
        if let a = arr("clouds__allowed") { cfg.cloudsAllowed = a }
        cfg.cloudsFile = str("clouds__file")
        // session
        cfg.sessionIdleTTL = int("session__idle_ttl") ?? cfg.sessionIdleTTL
        cfg.sessionMaxLifetime = int("session__max_lifetime") ?? cfg.sessionMaxLifetime
        cfg.sessionMaxSessions = int("session__max_sessions") ?? cfg.sessionMaxSessions
        cfg.sessionMaxStreamsPerSession = int("session__max_streams_per_session") ?? cfg.sessionMaxStreamsPerSession
        // policy
        if let b = bool("policy__read_only") { cfg.policyReadOnly = b }
        if let a = arr("policy__deny_resources") { cfg.policyDenyResources = a }
        cfg.policyMaxListLimit = int("policy__max_list_limit") ?? cfg.policyMaxListLimit
        cfg.policyMaxCallsPerMinute = int("policy__max_calls_per_minute") ?? cfg.policyMaxCallsPerMinute
        // client
        cfg.clientRequestTimeout = int("client__request_timeout") ?? cfg.clientRequestTimeout
        cfg.clientMaxConnectionsPerHost = int("client__max_connections_per_host") ?? cfg.clientMaxConnectionsPerHost
        // log
        cfg.logLevel = str("log__level") ?? cfg.logLevel
        cfg.logFormat = str("log__format") ?? cfg.logFormat
        if let b = bool("log__audit") { cfg.logAudit = b }
        return cfg
    }

    /// Parse a YAML file into flattened `__`-separated string values.
    private static func yamlValues(at path: String) -> [String: String] {
        guard FileManager.default.fileExists(atPath: path),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        guard let obj = try? Yams.load(yaml: text) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        flatten(prefix: "", obj: obj, into: &out)
        return out
    }

    private static func flatten(prefix: String, obj: [String: Any], into out: inout [String: String]) {
        for (key, value) in obj {
            let path = prefix.isEmpty ? key : prefix + "__" + key
            if let dict = value as? [String: Any] {
                flatten(prefix: path, obj: dict, into: &out)
            } else if let arr = value as? [Any] {
                out[path] = arr.compactMap { ($0 as? String) ?? ($0 as? Int).map(String.init) }
                    .joined(separator: ",")
            } else if let s = value as? String {
                out[path] = s
            } else if let i = value as? Int {
                out[path] = String(i)
            } else if let b = value as? Bool {
                out[path] = b ? "true" : "false"
            }
        }
    }

    /// Map a CLI flag name (camelCase) to the spec §11.2 `__`-separated key
    /// path. The flag name is sectioned by the section prefix it starts with
    /// (`server`, `auth`, `clouds`, `session`, `policy`, `client`, `log`); the
    /// remainder is camelCase-split on the following uppercase letters. A flag
    /// with no recognized section prefix is left as-is (camelCase split).
    ///
    ///   - `serverPort` → `server__port`
    ///   - `publicURL`  → `server__public_url` (a port-less server flag)
    ///   - `logLevel`   → `log__level`
    ///   - `readOnly`   → `policy__read_only`
    static func camelToDoubleUnderscore(_ s: String) -> String {
        // Sections whose flags carry no explicit section prefix in the CLI name.
        // These are disambiguated by a known flag-name table (see below).
        let sections: [String] = ["server", "auth", "clouds", "session", "policy", "client", "log"]

        // A map of bare CLI flag names (no section prefix) to their spec key
        // path, for flags whose section is not their prefix.
        let bare: [String: String] = [
            "host": "server__host",
            "port": "server__port",
            "publicURL": "server__public_url",
            "readOnly": "policy__read_only",
            "logLevel": "log__level",
            "logFormat": "log__format",
            "config": "config",
            "cloud": "clouds__default",
        ]
        if let mapped = bare[s] { return mapped }

        // Otherwise the flag starts with a section name (e.g. `serverPort`,
        // `authProfile`, `logLevel` when not in the bare table above).
        for section in sections {
            if s.hasPrefix(section), s.count > section.count {
                let rest = String(s.dropFirst(section.count))
                let split = camelSplit(rest)
                return section + "__" + split
            }
        }
        // No section prefix and not in the bare table: just camel-split.
        return camelSplit(s)
    }

    /// Split a camelCase string on uppercase boundaries into a lowercase
    /// underscore-separated string: `publicURL` → `public_url`, `port` → `port`.
    private static func camelSplit(_ s: String) -> String {
        var out = ""
        for (i, ch) in s.enumerated() {
            if ch.isUppercase && i != 0 {
                // Collapse an acronym run (URL) except the first capital.
                let prev = s[s.index(s.startIndex, offsetBy: i - 1)]
                if !(prev.isUppercase) { out += "_" }
            }
            out += ch.lowercased()
        }
        return out
    }
}
