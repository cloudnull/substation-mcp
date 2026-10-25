import Foundation
import HummingbirdMCP
import Logging
import OpenStackClient

// MARK: - Login page (URL-mode elicitation, spec §6.1b)

/// Wires the adapter's `login:` closure to the OpenStack `LoginMinter`.
///
/// The adapter (Task 17) already renders the HTML form and completion page;
/// this closure performs the Keystone exchange on POST and displays the minted
/// token on the completion page. It is **display-only**: the server stores no
/// token and never binds one to the elicitation id (WS-A, Option 2). The POST
/// body's secret is consumed by the minter and is never logged or stored.
public struct LoginPage: Sendable {
    private let minter: LoginMinter
    private let logger: Logger
    private let cloudsFileURL: URL?
    /// Roles that grant `openstack:write` (`policy.write_roles`). The form's
    /// "Access level" select is only a REQUEST; the granted scopes are the
    /// intersection of that request with what these roles allow, so the
    /// completion page can state the real access level.
    private let writeRoles: [String]

    public init(
        minter: LoginMinter,
        logger: Logger = Logger(label: "login-page"),
        cloudsFileURL: URL? = nil,
        writeRoles: [String] = PolicyRoles.defaultWriteRoles
    ) {
        self.minter = minter
        self.logger = logger
        self.cloudsFileURL = cloudsFileURL
        self.writeRoles = writeRoles
    }

    /// The `login:` closure for `MCPRoute.install`.
    public func handler() -> @Sendable (LoginRequest) async -> LoginResponse {
        let minter = self.minter
        let logger = self.logger
        let policy = PolicyRoles(writeRoles: writeRoles)
        return { req in
            let region = req.region?.isEmpty == false ? req.region! : nil
            let method: MintMethod
            switch req.method {
            case "password":
                method = MintMethod.password(
                    userID: req.userName ?? "",
                    domain: req.userDomain,
                    password: req.password ?? "",
                    projectName: req.projectName
                )
            case "federated":
                // Paste-token path (Route B): the operator pasted a token from
                // their cloud's portal session. We verify it is really an
                // OS-FEDERATION token and present it. A scoped fed token is used
                // directly; an unscoped one is presented without a scope block —
                // downstream calls will fail with "unscoped" if they need a
                // project, which is acceptable for read-only / whoami-style use.
                guard let ft = req.fedToken, !ft.isEmpty else {
                    logger.warning("Login mint failed", metadata: ["reason": .string("missing_fed_token")])
                    return LoginResponse(tokenID: "", storePath: "", completion: false, region: nil)
                }
                method = MintMethod.federationToken(tokenID: ft, isScoped: false)
            default: // "app-cred" (default)
                guard let id = req.appCredId, let secret = req.secret, !id.isEmpty, !secret.isEmpty else {
                    logger.warning("Login mint failed", metadata: [
                        "elicitationId": "\(req.elicitationId)",
                        "reason": "missing-app-cred-fields",
                    ])
                    return LoginResponse(tokenID: "", storePath: "", completion: false, region: nil)
                }
                method = MintMethod.applicationCredential(
                    id: id,
                    secret: Array(secret.utf8).map { Int8(bitPattern: $0) }
                )
            }

            do {
                let token = try await minter.mint(method: method, region: region, cloudsFile: cloudsFileURL)
                // The secret has been consumed by the minter. The minted token
                // is display-only: it is shown on the completion page (its
                // intended surface) but NEVER stored server-side — there is no
                // server-held token to zeroize (WS-A, Option 2).
                // Log the mint with only non-sensitive fields. A Keystone token
                // ID *is* the credential (the Bearer token), so the full id is
                // never logged — only a short prefix, enough to correlate a
                // mint with a later use without leaking the secret.
                let tokenRef = String(token.id.prefix(8))
                let tokenSummary = "\(tokenRef)…(\(token.id.count) chars)"
                // The access level the form asked for, intersected with what
                // this token's roles actually grant. A member who picked
                // "Read + write" gets read-only (and is told so on the
                // completion page) instead of a session that 403s later.
                let requested = MCPRoute.requestedScopes(req.scope)
                let granted = deriveScopes(roles: token.roles, policy: policy, requested: requested)
                logger.info("Login minted token", metadata: [
                    "elicitationId": "\(req.elicitationId)",
                    "tokenID": "\(tokenSummary)",
                    "project": "\(token.project.id)",
                    "scopes": "\(granted.map(\.rawValue).joined(separator: ","))",
                ])
                // The bearer the operator copies out carries both prefixes, so
                // the region and access-level choices survive into the session:
                // a Keystone token's scopes are otherwise re-derived from its
                // roles on every request, which would make the select purely
                // cosmetic. Only a read-only result needs a marker
                // (`scope:ro:`); read+write is what the roles already yield.
                let narrowed = granted.contains(.write) ? "" : "scope:ro:"
                let bearer = (region.map { "region:\($0):" } ?? "") + narrowed + token.id
                return LoginResponse(
                    tokenID: bearer,
                    storePath: "display-only",
                    completion: true,
                    region: region,
                    scopes: granted.map(\.rawValue)
                )
            } catch {
                // Log the mint failure with the structured error only — never
                // the raw error description, which may quote the request body
                // (i.e. the credential) on decode failures.
                var reason = "unknown"
                if let err = error as? OpenStackError {
                    reason = "keystone-\(err.status)"
                    // The message is our own (normalized) text, never the raw
                    // Keystone body — safe to log, and it distinguishes a real
                    // credential rejection (401) from a client-side decode bug
                    // (500) that previously looked like "bad credentials".
                    reason += ":\(err.code ?? String(err.message.prefix(80)))"
                }
                let failureReason: String?
                if let err = error as? OpenStackError,
                   err.message.contains(LoginMinter.needsProjectScopeMarker) {
                    failureReason = err.message.replacingOccurrences(
                        of: "\(LoginMinter.needsProjectScopeMarker): ", with: "")
                } else {
                    failureReason = nil
                }
                logger.warning("Login mint failed", metadata: [
                    "elicitationId": "\(req.elicitationId)",
                    "reason": "\(reason)",
                ])
                return LoginResponse(
                    tokenID: "",
                    storePath: "",
                    completion: false,
                    region: nil,
                    failureReason: failureReason
                )
            }
        }
    }
}
