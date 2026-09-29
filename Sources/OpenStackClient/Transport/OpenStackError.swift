import Foundation

public struct OpenStackError: Error, Sendable, Equatable {
    public let service: String
    public let status: Int
    public let code: String?
    public let message: String
    public let requestID: String?
    public let retriable: Bool
    public let hint: String?

    public init(
        service: String,
        status: Int,
        code: String? = nil,
        message: String,
        requestID: String? = nil,
        retriable: Bool = false,
        hint: String? = nil
    ) {
        self.service = service
        self.status = status
        self.code = code
        self.message = message
        self.requestID = requestID
        self.retriable = retriable
        self.hint = hint
    }

    /// Normalize a response body per spec §10.3 shapes.
    public static func normalize(
        body: Data?,
        status: Int,
        service: String,
        requestID: String?,
        hasAccessRules: Bool
    ) -> OpenStackError {
        var code: String?
        var message: String

        if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let neutronErr = json["NeutronError"] as? [String: Any] {
                // Neutron: {"NeutronError": {"type": ..., "message": ...}}
                code = neutronErr["type"] as? String
                message = neutronErr["message"] as? String ?? "Unknown error"
            } else if let err = json["error"] as? [String: Any] {
                // Keystone: {"error": {"code": ..., "message": ..., "title": ...}}
                code = err["code"] as? String
                message = err["message"] as? String ?? err["title"] as? String ?? "Unknown error"
            } else if let firstKey = json.keys.first,
                     let inner = json[firstKey] as? [String: Any],
                     let msg = inner["message"] as? String {
                // Nova: {"itemNotFound": {"message": "..."}} or {"badRequest": {"message": "..."}}
                code = firstKey
                message = msg
            } else {
                message = String(data: body, encoding: .utf8) ?? "Unknown error"
            }
        } else if let body, let text = String(data: body, encoding: .utf8) {
            // Glance: plain text body
            message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            message = "HTTP \(status)"
        }

        var hint: String?
        if status == 403 && hasAccessRules {
            hint = "the application credential's access rules do not allow METHOD PATH; regenerate with `openstack-mcp access-rules`"
        }

        let retriable = (status == 429 || status == 502 || status == 503 || status == 504)

        return OpenStackError(
            service: service,
            status: status,
            code: code,
            message: message,
            requestID: requestID,
            retriable: retriable,
            hint: hint
        )
    }
}
