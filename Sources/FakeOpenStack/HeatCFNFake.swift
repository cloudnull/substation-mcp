import Foundation
import Hummingbird
import NIOCore

/// CloudFormation (heat-api-cfn) fake.
///
/// The CFN wire protocol is AWS-query style: form-encoded POST to the service
/// root with `Action` + `Version`, XML responses. Auth in the fake accepts any
/// valid Keystone token (matching Rackspace's behavior where the token is the
/// AWSAccessKeyId and the signature check is skipped).
public struct HeatCFNFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        router.post("/cfn/v1") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.errorXML(status: .forbidden, code: "AuthFailure", message: "The security token included in the request is invalid")
            }
            var form = try await Self.readForm(req)
            // The client sends the action + params as query items; merge them
            // under the body form (body wins on collision).
            for (k, v) in req.uri.queryParameters {
                form[String(k)] = form[String(k)] ?? String(v)
            }
            // The AWS query-auth params (AWSAccessKeyId/Signature/…) are
            // accepted and ignored; X-Auth-Token is the real credential.
            guard let action = form["Action"] else {
                return Self.errorXML(status: .badRequest, code: "MissingParameter", message: "The request must contain the parameter Action")
            }
            switch action {
            case "ListStacks":
                let stacks = await state.listCFNStacks(projectID: token.projectID)
                return Self.ok(Self.listStacksXML(stacks))
            case "DescribeStacks":
                let stacks = await state.describeCFNStacks(projectID: token.projectID, name: form["StackName"])
                if let name = form["StackName"], stacks.isEmpty {
                    return Self.errorXML(status: .notFound, code: "ValidationError", message: "Stack with id \(name) does not exist")
                }
                return Self.ok(Self.describeStacksXML(stacks))
            case "CreateStack":
                guard let name = form["StackName"], !name.isEmpty else {
                    return Self.errorXML(status: .badRequest, code: "ValidationError", message: "StackName is a required parameter")
                }
                if name.range(of: "^[a-zA-Z][-a-zA-Z0-9]*$", options: .regularExpression) == nil {
                    return Self.errorXML(status: .badRequest, code: "ValidationError", message: "Stack names must match [a-zA-Z][-a-zA-Z0-9]*")
                }
                if await state.describeCFNStacks(projectID: token.projectID, name: name).isEmpty == false {
                    return Self.errorXML(status: .badRequest, code: "ValidationError", message: "Stack \(name) already exists")
                }
                let (params, tags) = Self.parseMembers(form)
                let stack = await state.createCFNStack(projectID: token.projectID, name: name, templateBody: form["TemplateBody"], parameters: params, tags: tags)
                return Self.ok("""
                <CreateStackResult><StackId>\(stack.id)</StackId></CreateStackResult>
                """)
            case "UpdateStack":
                guard let name = form["StackName"] else {
                    return Self.errorXML(status: .badRequest, code: "ValidationError", message: "StackName is a required parameter")
                }
                let (params, _) = Self.parseMembers(form)
                guard let stack = await state.updateCFNStack(name: name, projectID: token.projectID, templateBody: form["TemplateBody"], parameters: params) else {
                    return Self.errorXML(status: .notFound, code: "ValidationError", message: "Stack with id \(name) does not exist")
                }
                return Self.ok("""
                <UpdateStackResult><StackId>\(stack.id)</StackId></UpdateStackResult>
                """)
            case "DeleteStack":
                guard let name = form["StackName"] else {
                    return Self.errorXML(status: .badRequest, code: "ValidationError", message: "StackName is a required parameter")
                }
                guard await state.deleteCFNStack(name: name, projectID: token.projectID) else {
                    return Self.errorXML(status: .notFound, code: "ValidationError", message: "Stack with id \(name) does not exist")
                }
                return Self.ok("<DeleteStackResult/>")
            case "ValidateTemplate":
                guard let template = form["TemplateBody"], !template.isEmpty else {
                    return Self.errorXML(status: .badRequest, code: "ValidationError", message: "TemplateBody is a required parameter")
                }
                // The fake "validates" by extracting Parameters keys from a
                // JSON template; a template without Parameters validates with
                // an empty list. Unparseable JSON is a validation error.
                guard let data = template.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) != nil || template.contains("ROSTemplateFormatVersion") || template.contains("HeatTemplateFormatVersion") else {
                    return Self.errorXML(status: .badRequest, code: "ValidationError", message: "Template format is not valid JSON or YAML")
                }
                var keys: [String] = []
                if let data = template.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let params = obj["Parameters"] as? [String: Any] {
                    keys = params.keys.sorted()
                }
                let members = keys.map { "<member><ParameterKey>\($0)</ParameterKey></member>" }.joined()
                return Self.ok("""
                <ValidateTemplateResult><Parameters>\(members)</Parameters></ValidateTemplateResult>
                """)
            default:
                return Self.errorXML(status: .badRequest, code: "InvalidAction", message: "The action \(action) is not valid for this web service")
            }
        }
    }

    // MARK: - Helpers

    static func readForm(_ req: Request) async throws -> [String: String] {
        var data = Data()
        for try await buffer in req.body {
            data.append(contentsOf: buffer.readableBytesView)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        var form: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].removingPercentEncoding ?? String(parts[0])
            let value = parts[1].removingPercentEncoding ?? String(parts[1])
            form[key] = value
        }
        return form
    }

    /// Extract `Parameters.member.N.ParameterKey/Value` and
    /// `Tags.member.N.Key/Value` pairs from the form.
    static func parseMembers(_ form: [String: String]) -> (parameters: [(key: String, value: String)], tags: [(key: String, value: String)]) {
        var params: [(key: String, value: String)] = []
        var tags: [(key: String, value: String)] = []
        var n = 1
        while true {
            guard let k = form["Parameters.member.\(n).ParameterKey"] else { break }
            params.append((k, form["Parameters.member.\(n).ParameterValue"] ?? ""))
            n += 1
        }
        n = 1
        while true {
            guard let k = form["Tags.member.\(n).Key"] else { break }
            tags.append((k, form["Tags.member.\(n).Value"] ?? ""))
            n += 1
        }
        return (params, tags)
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func stackXML(_ stack: FakeState.FakeCFNStack, full: Bool) -> String {
        var parts = [
            "<StackId>\(stack.id)</StackId>",
            "<StackName>\(xmlEscape(stack.name))</StackName>",
            "<StackStatus>\(stack.status)</StackStatus>",
            "<CreationTime>\(stack.creationTime)</CreationTime>",
        ]
        if let reason = stack.statusReason { parts.append("<StackStatusReason>\(xmlEscape(reason))</StackStatusReason>") }
        if full {
            parts.append("<TemplateDescription>\(xmlEscape(stack.templateDescription))</TemplateDescription>")
            if !stack.parameters.isEmpty {
                let members = stack.parameters.map { "<member><ParameterKey>\(xmlEscape($0.key))</ParameterKey><ParameterValue>\(xmlEscape($0.value))</ParameterValue></member>" }.joined()
                parts.append("<Parameters>\(members)</Parameters>")
            }
            if !stack.tags.isEmpty {
                let members = stack.tags.map { "<member><Key>\(xmlEscape($0.key))</Key><Value>\(xmlEscape($0.value))</Value></member>" }.joined()
                parts.append("<Tags>\(members)</Tags>")
            }
        }
        return "<member>\(parts.joined())</member>"
    }

    static func listStacksXML(_ stacks: [FakeState.FakeCFNStack]) -> String {
        let members = stacks.map { stackXML($0, full: false) }.joined()
        return """
        <ListStacksResult><StackSummaries>\(members)</StackSummaries></ListStacksResult>
        """
    }

    static func describeStacksXML(_ stacks: [FakeState.FakeCFNStack]) -> String {
        let members = stacks.map { stackXML($0, full: true) }.joined()
        return """
        <DescribeStacksResult><Stacks>\(members)</Stacks></DescribeStacksResult>
        """
    }

    static func ok(_ result: String) -> Response {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>\n<\(resultPrefix(result))Response xmlns="http://cloudformation.amazonaws.com/doc/2010-05-15/">\(result)<ResponseMetadata><RequestId>fake-cfn-request</RequestId></ResponseMetadata></\(resultPrefix(result))Response>
        """
        return Response(status: .ok, headers: [.contentType: "text/xml"], body: .init(byteBuffer: .init(string: body)))
    }

    /// The action name for the enclosing element: `<Action>Result` → `<Action>Response`.
    static func resultPrefix(_ result: String) -> String {
        guard let start = result.range(of: "<"),
              let end = result[start.upperBound...].range(of: "Result>") else { return "Action" }
        return String(result[start.upperBound..<end.lowerBound])
    }

    static func errorXML(status: HTTPResponse.Status, code: String, message: String) -> Response {
        let body = """
        <ErrorResponse><Error><Type>Sender</Type><Code>\(code)</Code><Message>\(xmlEscape(message))</Message></Error><RequestId>fake-cfn-error</RequestId></ErrorResponse>
        """
        return Response(status: status, headers: [.contentType: "text/xml"], body: .init(byteBuffer: .init(string: body)))
    }
}
