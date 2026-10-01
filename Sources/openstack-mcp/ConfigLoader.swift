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
enum ConfigLoader {
    /// `args` maps the CLI flag names we already parsed (e.g. "host", "port")
    /// to their values; missing/nil values are skipped.
    static func load(args: [String: String?]) -> OpenStackMCPConfig {
        // Precedence: CLI > env > YAML > defaults. We build a merged dict
        // (lower priority first) and read from it.
        var values: [String: String] = [:]

        // 3. YAML file (lowest of the three).
        let configPath: String
        if let c = args["config"], let cc = c {
            configPath = cc
        } else {
            configPath = ProcessInfo.processInfo.environment["OSMCP__CONFIG"]
                ?? "/etc/openstack-mcp/config.yaml"
        }
        for (k, v) in yamlValues(at: configPath) {
            values[k] = v
        }

        // 2. Environment (OSMCP_ prefix, __ separator).
        for (key, val) in ProcessInfo.processInfo.environment {
            if key.hasPrefix("OSMCP_") {
                let trimmed = String(key.dropFirst("OSMCP_".count))
                let stripped = trimmed.hasPrefix("__") ? String(trimmed.dropFirst(2)) : trimmed
                values[stripped] = val
            }
        }

        // 1. CLI flags (highest).
        for (flag, val) in args {
            if let val {
                values[camelToDoubleUnderscore(flag)] = val
            }
        }

        return read(values)
    }

    private static func read(_ v: [String: String]) -> OpenStackMCPConfig {
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

    /// Map a camelCase CLI flag name to the double-underscore key path.
    private static func camelToDoubleUnderscore(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isUppercase { out += "_" + ch.lowercased() } else { out += String(ch) }
        }
        return out.hasPrefix("_") ? String(out.dropFirst()) : out
    }
}
