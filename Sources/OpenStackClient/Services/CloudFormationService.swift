import Foundation
import Logging

/// Region-bound Heat-CFN (CloudFormation) client.
///
/// Keystone service type: `cloudformation`. The CFN API is AWS-query style:
/// every call is a form-encoded request to the service root carrying
/// `Action` + `Version=2010-05-15` (plus AWS query-auth params). Responses are
/// XML; this client decodes the small, stable subset the tool surface needs.
///
/// Auth (verified live on Rackspace IAD3, 2026-10-18): heat-api-cfn accepts a
/// Keystone token as `AWSAccessKeyId` with a placeholder signature — the
/// signature check is skipped when the key resolves to a Keystone token — but
/// the token must carry the `heat_stack_user` role, otherwise every action
/// returns `AccessDenied` ("User is not authorized to perform action").
/// Rackspace grants `heat_stack_user` project-wide, so their tokens work
/// directly; generic clouds need a stack-domain user, which this client
/// surfaces as an honest 403 from the server.
public struct CloudFormationRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String
    let serviceType: String
    let defaultRegion: String?

    /// Empty: the catalog URL (e.g. `.../v1`) is the authoritative base.
    private let serviceRoot: String = ""
    private let catalogType: String = "cloudformation"

    private static let apiVersion = "2010-05-15"

    /// Route a request to the CFN endpoint from the token catalog.
    private func req(
        _ vt: ValidatedToken,
        _ region: String,
        method: String,
        query: [URLQueryItem]
    ) async throws -> (status: Int, body: Data, requestID: String?) {
        let ep = resolveServiceEndpoint(
            vt: vt, region: region, cloud: cloud,
            basePath: basePath, serviceRoot: serviceRoot,
            serviceType: catalogType, fullPath: ""
        )
        return try await transport.request(
            method: method,
            service: serviceType,
            path: ep.path,
            query: query,
            body: nil,
            tokenOverride: vt.token.id,
            extraHeaders: [("Content-Type", "application/x-www-form-urlencoded")],
            overrideBase: ep.overrideBase
        )
    }

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "cloudformation", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    // MARK: - Stacks

    public func listStacks(_ vt: ValidatedToken) async throws -> [CFNStack] {
        let region = try resolveRegion(vt)
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "cfn_stack", suffix: "list")
        if let cached = await cache.get(key, ttl: .seconds(60), as: [CFNStack].self) { return cached }
        let body = try await call(vt, region, action: "ListStacks", extra: [])
        let items = Self.parseStacks(from: body)
        await cache.put(key, ttl: .seconds(60), value: items)
        return items
    }

    /// `DescribeStacks` — full rows (parameters, outputs, tags). Heat returns
    /// the full row shape for ListStacks too, so this is the get path.
    public func describeStacks(_ vt: ValidatedToken, nameOrID: String? = nil) async throws -> [CFNStack] {
        let region = try resolveRegion(vt)
        var extra: [URLQueryItem] = []
        if let nameOrID {
            extra.append(URLQueryItem(name: "StackName", value: nameOrID))
        }
        let body = try await call(vt, region, action: "DescribeStacks", extra: extra)
        return Self.parseStacks(from: body)
    }

    public func createStack(_ vt: ValidatedToken, _ spec: CreateCFNStackSpec) async throws -> CFNStack {
        let region = try resolveRegion(vt)
        var extra: [URLQueryItem] = [URLQueryItem(name: "StackName", value: spec.stackName)]
        if let templateBody = spec.templateBody {
            extra.append(URLQueryItem(name: "TemplateBody", value: templateBody))
        }
        if let templateURL = spec.templateURL {
            extra.append(URLQueryItem(name: "TemplateURL", value: templateURL))
        }
        var idx = 1
        for (k, v) in spec.parameters.sorted(by: { $0.key < $1.key }) {
            extra.append(URLQueryItem(name: "Parameters.member.\(idx).ParameterKey", value: k))
            extra.append(URLQueryItem(name: "Parameters.member.\(idx).ParameterValue", value: v))
            idx += 1
        }
        idx = 1
        for (k, v) in spec.tags.sorted(by: { $0.key < $1.key }) {
            extra.append(URLQueryItem(name: "Tags.member.\(idx).Key", value: k))
            extra.append(URLQueryItem(name: "Tags.member.\(idx).Value", value: v))
            idx += 1
        }
        if spec.disableRollback {
            extra.append(URLQueryItem(name: "DisableRollback", value: "true"))
        }
        let body = try await call(vt, region, action: "CreateStack", extra: extra)
        await cache.invalidate(resource: "cfn_stack", tokenID: vt.token.id, region: region)
        // CreateStack returns only <StackId>.
        let stackID = Self.xmlValue(String(data: body, encoding: .utf8) ?? "", tag: "StackId") ?? ""
        return CFNStack(stackID: stackID, stackName: spec.stackName, stackStatus: "CREATE_IN_PROGRESS")
    }

    public func updateStack(_ vt: ValidatedToken, nameOrID: String, templateBody: String?, parameters: [String: String] = [:]) async throws -> CFNStack {
        let region = try resolveRegion(vt)
        var extra: [URLQueryItem] = [URLQueryItem(name: "StackName", value: nameOrID)]
        if let templateBody {
            extra.append(URLQueryItem(name: "TemplateBody", value: templateBody))
        }
        var idx = 1
        for (k, v) in parameters.sorted(by: { $0.key < $1.key }) {
            extra.append(URLQueryItem(name: "Parameters.member.\(idx).ParameterKey", value: k))
            extra.append(URLQueryItem(name: "Parameters.member.\(idx).ParameterValue", value: v))
            idx += 1
        }
        let body = try await call(vt, region, action: "UpdateStack", extra: extra)
        await cache.invalidate(resource: "cfn_stack", tokenID: vt.token.id, region: region)
        let stackID = Self.xmlValue(String(data: body, encoding: .utf8) ?? "", tag: "StackId") ?? nameOrID
        return CFNStack(stackID: stackID, stackName: nameOrID, stackStatus: "UPDATE_IN_PROGRESS")
    }

    public func deleteStack(_ vt: ValidatedToken, nameOrID: String) async throws {
        let region = try resolveRegion(vt)
        _ = try await call(vt, region, action: "DeleteStack", extra: [URLQueryItem(name: "StackName", value: nameOrID)])
        await cache.invalidate(resource: "cfn_stack", tokenID: vt.token.id, region: region)
    }

    public func validateTemplate(_ vt: ValidatedToken, templateBody: String) async throws -> [String] {
        let region = try resolveRegion(vt)
        let body = try await call(vt, region, action: "ValidateTemplate", extra: [URLQueryItem(name: "TemplateBody", value: templateBody)])
        let xml = String(data: body, encoding: .utf8) ?? ""
        var keys: [String] = []
        if let block = Self.xmlValueBlock(xml, container: "Parameters") {
            var idx = 1
            while let member = Self.xmlMember(block, tag: "member", index: idx) {
                if let k = Self.xmlValue(member, tag: "ParameterKey") { keys.append(k) }
                idx += 1
            }
        }
        return keys
    }

    // MARK: - Helpers

    /// One CFN action: AWS query-auth params + Keystone token as access key.
    private func call(_ vt: ValidatedToken, _ region: String, action: String, extra: [URLQueryItem]) async throws -> Data {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "Action", value: action),
            URLQueryItem(name: "Version", value: Self.apiVersion),
            URLQueryItem(name: "AWSAccessKeyId", value: vt.token.id),
            URLQueryItem(name: "SignatureVersion", value: "2"),
            URLQueryItem(name: "SignatureMethod", value: "HmacSHA256"),
            URLQueryItem(name: "Signature", value: "keystone"),
            URLQueryItem(name: "Timestamp", value: Self.timestamp()),
        ]
        query.append(contentsOf: extra)
        let result = try await req(vt, region, method: "POST", query: query)
        guard (200...299).contains(result.status) else {
            throw Self.normalizeError(body: result.body, status: result.status, requestID: result.requestID)
        }
        return result.body
    }

    /// CFN errors are AWS XML (`<ErrorResponse><Error><Code>…`), invisible to
    /// the JSON normalizer. Map AWS codes → HTTP semantics.
    static func normalizeError(body: Data, status: Int, requestID: String?) -> OpenStackError {
        let text = String(data: body, encoding: .utf8) ?? ""
        let code = xmlValue(text, tag: "Code")
        let message = xmlValue(text, tag: "Message") ?? String(text.prefix(200))
        let mapped: Int
        switch code {
        case "AccessDenied", "AuthFailure": mapped = status >= 400 ? status : 403
        case "ValidationError": mapped = status >= 400 ? status : 400
        case "Throttling": mapped = status >= 400 ? status : 429
        default: mapped = status >= 400 ? status : 500
        }
        return OpenStackError(service: "cloudformation", status: mapped, message: message, requestID: requestID)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    /// Heat stack names are `[a-zA-Z][-a-zA-Z0-9]*`; anything else is a
    /// stack-id ARN/uuid.
    static func isStackName(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    // MARK: - Minimal XML extraction
    //
    // CFN responses are XML. The shapes are small and stable; rather than a
    // full XML tree we extract the tags the models need. `parseStacks` walks
    // <member> blocks of a stack list; `xmlValue` grabs the first <tag>…</tag>.

    static func xmlValue(_ xml: String, tag: String) -> String? {
        let open = "<\(tag)>", close = "</\(tag)>"
        guard let start = xml.range(of: open) else { return nil }
        guard let end = xml[start.upperBound...].range(of: close) else { return nil }
        return unescapeXML(String(xml[start.upperBound..<end.lowerBound]))
    }

    /// The Nth `<tag>…</tag>` block's inner text (members of a list).
    /// Brute-force scan for the matching close tag so nested same-name
    /// blocks (`<member>` inside `<member>`) don't truncate the block.
    static func xmlMember(_ xml: String, tag: String, index: Int) -> String? {
        let open = "<\(tag)>", close = "</\(tag)>"
        var search = xml[...]
        var found = 0
        while true {
            guard let start = search.range(of: open) else { return nil }
            var depth = 1
            var cursor = search[start.upperBound...]
            var end: Range<Substring.Index>?
            while depth > 0 {
                let nextOpen = cursor.range(of: open)
                let nextClose = cursor.range(of: close)
                switch (nextOpen, nextClose) {
                case (.some(let o), .some(let c)) where o.lowerBound < c.lowerBound:
                    depth += 1
                    cursor = cursor[o.upperBound...]
                case (.some, .some(let c)):
                    depth -= 1
                    if depth == 0 { end = c }
                    cursor = cursor[c.upperBound...]
                case (.some(let o), nil):
                    cursor = cursor[o.upperBound...]
                case (nil, .some(let c)):
                    depth -= 1
                    if depth == 0 { end = c }
                    cursor = cursor[c.upperBound...]
                case (nil, nil):
                    return nil
                }
            }
            guard let end else { return nil }
            found += 1
            if found == index { return String(search[start.upperBound..<end.lowerBound]) }
            search = search[end.upperBound...]
        }
    }

    static func parseStacks(from data: Data) -> [CFNStack] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        guard let list = xmlValueBlock(xml, container: "StackSummaries") ?? xmlValueBlock(xml, container: "Stacks") else { return [] }
        var stacks: [CFNStack] = []
        var idx = 1
        while let member = xmlMember(list, tag: "member", index: idx) {
            stacks.append(parseStack(member))
            idx += 1
        }
        return stacks
    }

    /// Inner text of the FIRST <container>…</container> (not the short-form
    /// `xmlValue`, which stops at the first nested close tag).
    static func xmlValueBlock(_ xml: String, container: String) -> String? {
        let open = "<\(container)", close = "</\(container)>"
        guard let start = xml.range(of: open) else { return nil }
        // Skip to the end of the opening tag (may carry attributes).
        guard let tagEnd = xml[start.upperBound...].range(of: ">") else { return nil }
        guard let end = xml[tagEnd.upperBound...].range(of: close) else { return nil }
        return String(xml[tagEnd.upperBound..<end.lowerBound])
    }

    static func parseStack(_ member: String) -> CFNStack {
        var s = CFNStack(stackID: xmlValue(member, tag: "StackId") ?? "",
                         stackName: xmlValue(member, tag: "StackName") ?? "",
                         stackStatus: xmlValue(member, tag: "StackStatus") ?? "UNKNOWN",
                         stackStatusReason: xmlValue(member, tag: "StackStatusReason"),
                         creationTime: xmlValue(member, tag: "CreationTime") ?? "",
                         deletionTime: xmlValue(member, tag: "DeletionTime"),
                         templateDescription: xmlValue(member, tag: "TemplateDescription"))
        if let paramsBlock = xmlValueBlock(member, container: "Parameters") {
            var idx = 1
            while let m = xmlMember(paramsBlock, tag: "member", index: idx) {
                if let k = xmlValue(m, tag: "ParameterKey") {
                    s.parameters.append(CFNParameter(key: k, value: xmlValue(m, tag: "ParameterValue") ?? ""))
                }
                idx += 1
            }
        }
        if let outsBlock = xmlValueBlock(member, container: "Outputs") {
            var idx = 1
            while let m = xmlMember(outsBlock, tag: "member", index: idx) {
                if let k = xmlValue(m, tag: "OutputKey") {
                    s.outputs.append(CFNOutput(outputKey: k, outputValue: xmlValue(m, tag: "OutputValue") ?? "", description: xmlValue(m, tag: "Description")))
                }
                idx += 1
            }
        }
        if let tagsBlock = xmlValueBlock(member, container: "Tags") {
            var idx = 1
            while let m = xmlMember(tagsBlock, tag: "member", index: idx) {
                if let k = xmlValue(m, tag: "Key") {
                    s.tags.append(CFNTag(key: k, value: xmlValue(m, tag: "Value") ?? ""))
                }
                idx += 1
            }
        }
        return s
    }

    static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: serviceType, region: region, vt: vt)
        return region
    }
}

/// Heat-CFN (CloudFormation) client.
public struct CloudFormationService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "cloudformation/v1") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> CloudFormationRegion {
        CloudFormationRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "cloudformation/v1", defaultRegion: region ?? cloud.regionName)
    }
}
