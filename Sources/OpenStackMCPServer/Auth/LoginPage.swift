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

    public init(
        minter: LoginMinter,
        logger: Logger = Logger(label: "login-page")
    ) {
        self.minter = minter
        self.logger = logger
    }

    /// The `login:` closure for `MCPRoute.install`.
    public func handler() -> @Sendable (LoginRequest) async -> LoginResponse {
        let minter = self.minter
        let logger = self.logger
        return { req in
            let method: MintMethod
            switch req.method {
            case "password":
                method = MintMethod.password(
                    userID: req.userName ?? "",
                    domain: req.userDomain,
                    password: req.password ?? "",
                    projectName: req.projectName
                )
            default: // "app-cred" (default)
                guard let id = req.appCredId, let secret = req.secret, !id.isEmpty, !secret.isEmpty else {
                    logger.warning("Login mint failed", metadata: [
                        "elicitationId": "\(req.elicitationId)",
                        "reason": "missing-app-cred-fields",
                    ])
                    return LoginResponse(tokenID: "", storePath: "", completion: false)
                }
                method = MintMethod.applicationCredential(
                    id: id,
                    secret: Array(secret.utf8).map { Int8(bitPattern: $0) }
                )
            }

            do {
                let token = try await minter.mint(method: method)
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
                logger.info("Login minted token", metadata: [
                    "elicitationId": "\(req.elicitationId)",
                    "tokenID": "\(tokenSummary)",
                    "project": "\(token.project.id)",
                ])
                return LoginResponse(
                    tokenID: token.id,
                    storePath: "display-only",
                    completion: true
                )
            } catch {
                // Log the mint failure with the structured error only — never
                // the raw error description, which may quote the request body
                // (i.e. the credential) on decode failures.
                var reason = "unknown"
                if let err = error as? OpenStackError {
                    reason = "keystone-\(err.status)"
                }
                logger.warning("Login mint failed", metadata: [
                    "elicitationId": "\(req.elicitationId)",
                    "reason": "\(reason)",
                ])
                logger.warning("Login mint failed", metadata: [
                    "elicitationId": "\(req.elicitationId)",
                    "error": "\(error)",
                ])
                return LoginResponse(
                    tokenID: "",
                    storePath: "",
                    completion: false
                )
            }
        }
    }
}
