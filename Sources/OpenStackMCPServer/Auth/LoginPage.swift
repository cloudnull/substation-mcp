import Foundation
import HummingbirdMCP
import Logging
import OpenStackClient

// MARK: - Login page (URL-mode elicitation, spec §6.1b)

/// Wires the adapter's `login:` closure to the OpenStack `LoginMinter` and
/// `TokenStore`.
///
/// The adapter (Task 17) already renders the HTML form and completion page;
/// this closure performs the Keystone exchange on POST and stores the
/// minted token bound to the elicitation id (the one stateful element the
/// spec mandates). The POST body's secret is consumed by the minter and is
/// never logged or stored — only the resulting token id is kept.
public struct LoginPage: Sendable {
    private let minter: LoginMinter
    private let tokenStore: TokenStore
    private let logger: Logger

    public init(
        minter: LoginMinter,
        tokenStore: TokenStore,
        logger: Logger = Logger(label: "login-page")
    ) {
        self.minter = minter
        self.tokenStore = tokenStore
        self.logger = logger
    }

    /// The `login:` closure for `MCPRoute.install`.
    public func handler() -> @Sendable (LoginRequest) async -> LoginResponse {
        let minter = self.minter
        let tokenStore = self.tokenStore
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
                // The secret has been consumed by the minter; only the token
                // (with metadata) is stored, bound to the elicitation id.
                await tokenStore.bind(sessionId: req.elicitationId, token: token)
                // Log the mint with only non-sensitive fields (the token id
                // and project); the error below carries a generic reason.
                logger.info("Login minted token", metadata: [
                    "elicitationId": "\(req.elicitationId)",
                    "tokenID": "\(token.id)",
                    "project": "\(token.project.id)",
                ])
                return LoginResponse(
                    tokenID: token.id,
                    storePath: "session:\(req.elicitationId)",
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
