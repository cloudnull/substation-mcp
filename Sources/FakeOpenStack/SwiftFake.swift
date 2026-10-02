import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Swift (object storage) implementation.
///
/// Routes live under `/swift/v1/<account>/*` where `<account>` is the tenant
/// (project name). Errors use the Swift shape: plain-text body with the status
/// line. Container listings are a bare JSON array of [name, count, bytes];
/// object listings are a bare JSON array of object metadata.
public struct SwiftFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/swift/v1"

        // The Hummingbird router matches static path segments; the account is a
        // variable segment, so we register a single catch-all handler under the
        // account path and parse the container/object from the remainder.
        //
        // Routes:
        //   GET    /swift/v1/{account}                       -> list containers
        //   HEAD   /swift/v1/{account}/{container}           -> get container
        //   PUT    /swift/v1/{account}/{container}           -> create container
        //   DELETE /swift/v1/{account}/{container}           -> delete container
        //   GET    /swift/v1/{account}/{container}           -> list objects
        //   GET    /swift/v1/{account}/{container}/{object}  -> get object (metadata)
        //   PUT    /swift/v1/{account}/{container}/{object}  -> create object
        //   DELETE /swift/v1/{account}/{container}/{object}  -> delete object

        // Because the account segment is dynamic, we register against a
        // well-known account path. The fake tokens' project names are used as
        // the account; the client sends `token.project.name`. We register the
        // routes for both seeded project names and a generic handler via the
        // router's path parameters.

        // Container routes (account = :account, container = :container). The
        // path parameters are read from the request context (ctx.parameters),
        // the proper Hummingbird API — not by re-parsing the URI.
        router.get("\(base)/:account") { req, ctx in
            await Self.containerList(state, req)
        }
        router.put("\(base)/:account/:container") { req, ctx in
            await Self.containerCreate(state, req, container: ctx.parameters.get("container") ?? "")
        }
        router.delete("\(base)/:account/:container") { req, ctx in
            await Self.containerDelete(state, req, container: ctx.parameters.get("container") ?? "")
        }

        // Object routes.
        router.get("\(base)/:account/:container/:object") { req, ctx in
            await Self.objectGet(state, req, container: ctx.parameters.get("container") ?? "", object: ctx.parameters.get("object") ?? "")
        }
        router.put("\(base)/:account/:container/:object") { req, ctx in
            await Self.objectCreate(state, req, container: ctx.parameters.get("container") ?? "", object: ctx.parameters.get("object") ?? "")
        }
        router.delete("\(base)/:account/:container/:object") { req, ctx in
            await Self.objectDelete(state, req, container: ctx.parameters.get("container") ?? "", object: ctx.parameters.get("object") ?? "")
        }

        // Object list = GET on the container (no object segment).
        router.get("\(base)/:account/:container") { req, ctx in
            await Self.objectList(state, req, container: ctx.parameters.get("container") ?? "")
        }
    }

    // MARK: - Containers

    static func containerList(_ state: FakeState, _ req: Request) async -> Response {
        guard let tokenID = req.headers[FakeHeaders.xAuthToken],
              let token = await state.validateToken(tokenID) else {
            return Self.textError(status: .unauthorized, message: "401 Unauthorized")
        }
        let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
        let marker = Self.queryParam("marker", from: req)
        let prefix = Self.queryParam("prefix", from: req)
        let ctns = await state.listContainers(projectID: token.projectID, prefix: prefix, limit: limit, marker: marker)
        var items: [String] = []
        for ctn in ctns {
            let count = await state.countObjects(projectID: token.projectID, container: ctn.name)
            let bytes = await state.sumObjectBytes(projectID: token.projectID, container: ctn.name)
            items.append("[\"\(ctn.name)\",\(count),\(bytes)]")
        }
        return Self.jsonResponse(status: .ok, body: "[\(items.joined(separator: ","))]")
    }

    static func containerCreate(_ state: FakeState, _ req: Request, container: String) async -> Response {
        guard let tokenID = req.headers[FakeHeaders.xAuthToken],
              let token = await state.validateToken(tokenID) else {
            return Self.textError(status: .unauthorized, message: "401 Unauthorized")
        }
        guard !container.isEmpty else {
            return Self.textError(status: .notFound, message: "404 Not Found")
        }
        let ctn = container
        var quota: Int? = nil
        if let q = req.headers[HTTPField.Name("X-Container-Quota-Bytes")!] {
            quota = Int(q)
        }
        var metadata: [String: String] = [:]
        for field in req.headers {
            let nameStr = String(field.name)
            if nameStr.lowercased().hasPrefix("x-container-meta-") {
                metadata[String(nameStr.dropFirst("x-container-meta-".count))] = field.value
            }
        }
        guard await state.createContainer(projectID: token.projectID, name: ctn, quotaBytes: quota, metadata: metadata) != nil else {
            return Self.textError(status: .conflict, message: "409 Container Exists")
        }
        return Self.textResponse(status: .noContent, message: "")
    }

    static func containerDelete(_ state: FakeState, _ req: Request, container: String) async -> Response {
        guard let tokenID = req.headers[FakeHeaders.xAuthToken],
              let token = await state.validateToken(tokenID) else {
            return Self.textError(status: .unauthorized, message: "401 Unauthorized")
        }
        guard !container.isEmpty else {
            return Self.textError(status: .notFound, message: "404 Not Found")
        }
        let ctn = container
        guard await state.deleteContainer(name: ctn, projectID: token.projectID) else {
            return Self.textError(status: .notFound, message: "404 Container Not Found")
        }
        return Self.textResponse(status: .noContent, message: "")
    }

    // MARK: - Objects

    static func objectList(_ state: FakeState, _ req: Request, container: String) async -> Response {
        guard let tokenID = req.headers[FakeHeaders.xAuthToken],
              let token = await state.validateToken(tokenID) else {
            return Self.textError(status: .unauthorized, message: "401 Unauthorized")
        }
        guard !container.isEmpty else {
            return Self.textError(status: .notFound, message: "404 Not Found")
        }
        let ctn = container
        // If the container doesn't exist, 404.
        guard await state.getContainer(name: ctn, projectID: token.projectID) != nil else {
            return Self.textError(status: .notFound, message: "404 Container Not Found")
        }
        let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
        let marker = Self.queryParam("marker", from: req)
        let prefix = Self.queryParam("prefix", from: req)
        let objs = await state.listObjects(projectID: token.projectID, container: ctn, prefix: prefix, limit: limit, marker: marker)
        let items = objs.map { Self.objectJSON($0) }.joined(separator: ",")
        return Self.jsonResponse(status: .ok, body: "[\(items)]")
    }

    static func objectGet(_ state: FakeState, _ req: Request, container: String, object: String) async -> Response {
        guard let tokenID = req.headers[FakeHeaders.xAuthToken],
              let token = await state.validateToken(tokenID) else {
            return Self.textError(status: .unauthorized, message: "401 Unauthorized")
        }
        guard !container.isEmpty, !object.isEmpty else {
            return Self.textError(status: .notFound, message: "404 Not Found")
        }
        let ctn = container
        let objName = object
        guard let obj = await state.getObject(projectID: token.projectID, container: ctn, name: objName) else {
            return Self.textError(status: .notFound, message: "404 Object Not Found")
        }
        // The client passes ?format=json; serve metadata as a JSON object.
        return Self.jsonResponse(status: .ok, body: Self.objectJSON(obj))
    }

    static func objectCreate(_ state: FakeState, _ req: Request, container: String, object: String) async -> Response {
        guard let tokenID = req.headers[FakeHeaders.xAuthToken],
              let token = await state.validateToken(tokenID) else {
            return Self.textError(status: .unauthorized, message: "401 Unauthorized")
        }
        guard !container.isEmpty, !object.isEmpty else {
            return Self.textError(status: .notFound, message: "404 Not Found")
        }
        let ctn = container
        let objName = object
        // Swift: the container must exist (409 if the object collides is a PUT
        // that simply overwrites; we require the container).
        guard await state.getContainer(name: ctn, projectID: token.projectID) != nil else {
            return Self.textError(status: .notFound, message: "404 Container Not Found")
        }
        // The transport sends a default `Content-Type: application/json` AND
        // the object's own content type as an extra header. Prefer the last one
        // (the object's), which is what real Swift uses for the stored type.
        var contentType = "application/octet-stream"
        var lastCT: String? = nil
        for field in req.headers where String(field.name) == "Content-Type" {
            lastCT = field.value
        }
        if let ct = lastCT, !ct.hasPrefix("application/json") {
            contentType = ct
        }
        var metadata: [String: String] = [:]
        for field in req.headers {
            let nameStr = String(field.name)
            if nameStr.lowercased().hasPrefix("x-object-meta-") {
                metadata[String(nameStr.dropFirst("x-object-meta-".count))] = field.value
            }
        }
        let data = (try? await Self.readBody(req)) ?? Data()
        _ = await state.createObject(projectID: token.projectID, container: ctn, name: objName, data: data, contentType: contentType, metadata: metadata)
        return Self.textResponse(status: .noContent, message: "")
    }

    static func objectDelete(_ state: FakeState, _ req: Request, container: String, object: String) async -> Response {
        guard let tokenID = req.headers[FakeHeaders.xAuthToken],
              let token = await state.validateToken(tokenID) else {
            return Self.textError(status: .unauthorized, message: "401 Unauthorized")
        }
        guard !container.isEmpty, !object.isEmpty else {
            return Self.textError(status: .notFound, message: "404 Not Found")
        }
        let ctn = container
        let objName = object
        guard await state.deleteObject(projectID: token.projectID, container: ctn, name: objName) else {
            return Self.textError(status: .notFound, message: "404 Object Not Found")
        }
        return Self.textResponse(status: .noContent, message: "")
    }

    // MARK: - JSON builders

    static func objectJSON(_ obj: FakeState.FakeObject) -> String {
        var parts: [String] = []
        parts.append("\"name\":\"\(obj.name)\"")
        parts.append("\"size\":\(obj.size)")
        parts.append("\"content_type\":\"\(obj.contentType)\"")
        parts.append("\"deleted\":false")
        parts.append("\"hash\":\"\(Self.md5(obj.data))\"")
        let meta = obj.metadata.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        parts.append("\"metadata\":{\(meta)}")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func md5(_ data: Data) -> String {
        // A cheap stand-in hash (not real MD5); the fake only needs a stable
        // per-content string.
        var h: UInt64 = 0
        for b in data { h = (h &* 31) &+ UInt64(b &+ 48) }
        return String(h, radix: 16)
    }

    // MARK: - Helpers

    static func queryParam(_ name: String, from req: Request) -> String? {
        req.uri.queryParameters[Substring(name)].map { String($0) }
    }

    static func readBody(_ req: Request) async throws -> Data {
        var data = Data()
        for try await buffer in req.body {
            data.append(contentsOf: buffer.readableBytesView)
        }
        return data
    }

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: body))
        )
    }

    static func textError(status: HTTPResponse.Status, message: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "text/plain"],
            body: .init(byteBuffer: .init(string: message))
        )
    }

    static func textResponse(status: HTTPResponse.Status, message: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "text/plain"],
            body: .init(byteBuffer: .init(string: message))
        )
    }
}
