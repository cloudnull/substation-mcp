import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Cinder v3 implementation.
///
/// Routes live under `/cinder/v3/*`. Every route requires the
/// `OpenStack-API-Version: volume 3.x` header — requests that omit it are
/// rejected with 400, which pins the header contract on the client.
/// Errors use the Cinder shape: `{"badRequest": {"message": ...}}` /
/// `{"itemNotFound": {"message": ...}}`.
public struct CinderFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/cinder/v3"

        // MARK: - Volumes

        router.get("\(base)/volumes/detail") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            guard let apiVersion = req.headers[FakeHeaders.openstackAPIVersion] else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            _ = apiVersion
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let vols = await state.listVolumes(projectID: token.projectID, limit: limit, marker: marker)
            let items = vols.map { Self.volumeJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"volumes":[\(items)]}
            """)
        }

        router.get("\(base)/volumes/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let vol = await state.getVolume(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Volume \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"volume":\(Self.volumeJSON(vol))}
            """)
        }

        router.post("\(base)/volumes") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            let body = try await Self.readBody(req)
            let volBody = Self.objectForKey("volume", in: body) ?? body
            let name = Self.extractString("name", from: volBody) ?? ""
            let size = Self.extractInt("size", from: volBody) ?? 1
            let volumeType = Self.extractString("volume_type", from: volBody) ?? "lvmdriver-1"
            let imageID = Self.extractString("image_id", from: volBody)
            let sourceVolID = Self.extractString("source_vol_id", from: volBody)
            let snapshotID = Self.extractString("snapshot_id", from: volBody)
            let description = Self.extractString("description", from: volBody) ?? ""
            let availabilityZone = Self.extractString("availability_zone", from: volBody)
            let multiattach = Self.extractBool("multiattach", from: volBody) ?? false
            let vol = await state.createVolume(
                projectID: token.projectID,
                name: name,
                size: size,
                volumeType: volumeType,
                imageID: imageID,
                sourceVolumeID: sourceVolID,
                snapshotID: snapshotID,
                description: description,
                availabilityZone: availabilityZone,
                multiattach: multiattach
            )
            return Self.jsonResponse(status: .created, body: """
            {"volume":\(Self.volumeJSON(vol))}
            """)
        }

        router.delete("\(base)/volumes/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteVolume(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Volume \(id) could not be found.")
            }
            return Response(status: .accepted)
        }

        router.post("\(base)/volumes/:id/action") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            let id = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)

            if body.contains("os-extend") {
                let newSize = Self.extractInt("new_size", from: Self.objectForKey("os-extend", in: body) ?? body)
                guard newSize != nil, let vol = await state.updateVolume(id: id, projectID: token.projectID, size: newSize) else {
                    return Self.itemNotFound(message: "Volume \(id) could not be found.")
                }
                return Self.jsonResponse(status: .accepted, body: """
                {"volume":\(Self.volumeJSON(vol))}
                """)
            }
            if body.contains("os-retype") {
                let newType = Self.extractString("new_type", from: Self.objectForKey("os-retype", in: body) ?? body)
                guard newType != nil, let vol = await state.updateVolume(id: id, projectID: token.projectID, volumeType: newType) else {
                    return Self.itemNotFound(message: "Volume \(id) could not be found.")
                }
                return Self.jsonResponse(status: .accepted, body: """
                {"volume":\(Self.volumeJSON(vol))}
                """)
            }
            if body.contains("os-set_bootable") {
                let bootable = Self.extractBool("bootable", from: Self.objectForKey("os-set_bootable", in: body) ?? body)
                guard let vol = await state.updateVolume(id: id, projectID: token.projectID, bootable: bootable) else {
                    return Self.itemNotFound(message: "Volume \(id) could not be found.")
                }
                return Self.jsonResponse(status: .accepted, body: """
                {"volume":\(Self.volumeJSON(vol))}
                """)
            }
            if body.contains("os-volume_upload_to_image") {
                guard let imageID = await state.uploadVolumeToImage(id: id, projectID: token.projectID) else {
                    return Self.itemNotFound(message: "Volume \(id) could not be found.")
                }
                return Self.jsonResponse(status: .accepted, body: """
                {"imageId":"\(imageID)"}
                """)
            }
            if body.contains("reset-status") {
                let status = Self.extractString("status", from: Self.objectForKey("reset-status", in: body) ?? body) ?? "available"
                guard let vol = await state.getVolume(id: id, projectID: token.projectID) else {
                    return Self.itemNotFound(message: "Volume \(id) could not be found.")
                }
                let _ = status
                return Self.jsonResponse(status: .accepted, body: """
                {"volume":\(Self.volumeJSON(vol))}
                """)
            }
            return Self.cinderError(status: .badRequest, type: "badRequest", message: "Unknown volume action.")
        }

        // MARK: - Volume Types
        //
        // Real Cinder v3 registers the collection as `types`, project-scoped:
        // `GET/POST /v3/{project_id}/types`, `GET/DELETE /v3/{project_id}/types/{id}`
        // (cinder/api/v3/router.py `mapper.resource("type", "types", ...)`;
        // api-ref/source/v3/volumes-v3-types.inc). `volume-types` is NOT a Cinder
        // route — serving it here is what let the client's wrong path pass the
        // suite while 404'ing on Rackspace. The routes below mirror the real
        // mapper, including Cinder's microversion-3.67 unscoped alias `/types`,
        // which is why the project segment is a literal UUID-ish segment and not
        // a catch-all.

        router.get("\(base)/:projectId/types") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            // Cinder scopes the list to the token's project: a token may only
            // address its own project id in the path.
            let projectId = ctx.parameters.get("projectId") ?? ""
            guard projectId == token.projectID else {
                return Self.forbidden(message: "Not allowed to access project \(projectId).")
            }
            let types = await state.listVolumeTypes()
            let items = types.map { Self.volumeTypeJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"volume_types":[\(items)]}
            """)
        }

        router.get("\(base)/:projectId/types/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            let projectId = ctx.parameters.get("projectId") ?? ""
            guard projectId == token.projectID else {
                return Self.forbidden(message: "Not allowed to access project \(projectId).")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let vt = await state.getVolumeType(id: id) else {
                return Self.itemNotFound(message: "Volume type \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"volume_type":\(Self.volumeTypeJSON(vt))}
            """)
        }

        router.post("\(base)/:projectId/types") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            let projectId = ctx.parameters.get("projectId") ?? ""
            guard projectId == token.projectID else {
                return Self.forbidden(message: "Not allowed to access project \(projectId).")
            }
            let body = try await Self.readBody(req)
            // Cinder's create body is the snake_case `volume_type` envelope.
            guard Self.objectForKey("volume_type", in: body) != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Could not parse body for volume_type.")
            }
            let vtBody = Self.objectForKey("volume_type", in: body) ?? body
            let name = Self.extractString("name", from: vtBody) ?? "new-type"
            let vt = await state.createVolumeType(name: name)
            return Self.jsonResponse(status: .created, body: """
            {"volume_type":\(Self.volumeTypeJSON(vt))}
            """)
        }

        router.delete("\(base)/:projectId/types/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            let projectId = ctx.parameters.get("projectId") ?? ""
            guard projectId == token.projectID else {
                return Self.forbidden(message: "Not allowed to access project \(projectId).")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteVolumeType(id: id) else {
                return Self.itemNotFound(message: "Volume type \(id) could not be found.")
            }
            return Response(status: .accepted)
        }

        // MARK: - Snapshots
        //
        // Cinder registers snapshots project-scoped:
        // `GET /v3/{project_id}/snapshots`, `GET /v3/{project_id}/snapshots/detail`,
        // `POST /v3/{project_id}/snapshots`, `GET|DELETE /v3/{project_id}/snapshots/{id}`
        // (cinder/api/v3/router.py `mapper.resource("snapshot", "snapshots",
        // collection: {'detail': 'GET'})`; api-ref volumes-v3-snapshots.inc).
        // `snapshots/detail` is registered BEFORE `snapshots/:id` so the literal
        // `detail` segment wins over the id parameter, as it does in Cinder.

        router.get("\(base)/:projectId/snapshots/detail") { req, ctx in
            guard let token = await Self.token(req, state: state) else { return Self.unauthorized() }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            guard Self.projectMatches(ctx, token: token) else { return Self.projectForbidden(ctx) }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let snaps = await state.listSnapshots(projectID: token.projectID, limit: limit, marker: marker)
            let items = snaps.map { Self.snapshotJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"snapshots":[\(items)]}
            """)
        }

        router.get("\(base)/:projectId/snapshots") { req, ctx in
            guard let token = await Self.token(req, state: state) else { return Self.unauthorized() }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            guard Self.projectMatches(ctx, token: token) else { return Self.projectForbidden(ctx) }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let snaps = await state.listSnapshots(projectID: token.projectID, limit: limit, marker: marker)
            let items = snaps.map { Self.snapshotJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"snapshots":[\(items)]}
            """)
        }

        router.get("\(base)/:projectId/snapshots/:id") { req, ctx in
            guard let token = await Self.token(req, state: state) else { return Self.unauthorized() }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            guard Self.projectMatches(ctx, token: token) else { return Self.projectForbidden(ctx) }
            let id = ctx.parameters.get("id") ?? ""
            guard let snap = await state.getSnapshot(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Snapshot \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"snapshot":\(Self.snapshotJSON(snap))}
            """)
        }

        router.post("\(base)/:projectId/snapshots") { req, ctx in
            guard let token = await Self.token(req, state: state) else { return Self.unauthorized() }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            guard Self.projectMatches(ctx, token: token) else { return Self.projectForbidden(ctx) }
            let body = try await Self.readBody(req)
            let snapBody = Self.objectForKey("snapshot", in: body) ?? body
            let volumeID = Self.extractString("volume_id", from: snapBody) ?? ""
            let name = Self.extractString("name", from: snapBody) ?? ""
            let force = Self.extractBool("force", from: snapBody) ?? false
            guard let snap = await state.createSnapshot(projectID: token.projectID, volumeID: volumeID, name: name, force: force) else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Volume \(volumeID) could not be found.")
            }
            return Self.jsonResponse(status: .created, body: """
            {"snapshot":\(Self.snapshotJSON(snap))}
            """)
        }

        router.delete("\(base)/:projectId/snapshots/:id") { req, ctx in
            guard let token = await Self.token(req, state: state) else { return Self.unauthorized() }
            guard Self.projectMatches(ctx, token: token) else { return Self.projectForbidden(ctx) }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteSnapshot(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Snapshot \(id) could not be found.")
            }
            return Response(status: .accepted)
        }

        // MARK: - Backups
        //
        // Also project-scoped in Cinder: `GET|POST /v3/{project_id}/backups`,
        // `GET /v3/{project_id}/backups/detail`,
        // `GET|DELETE /v3/{project_id}/backups/{id}`,
        // `POST /v3/{project_id}/backups/{id}/restore`
        // (cinder/api/v3/router.py `mapper.resource("backup", "backups",
        // collection: {'detail': 'GET'})`; api-ref ext-backups.inc).

        router.get("\(base)/:projectId/backups/detail") { req, ctx in
            guard let token = await Self.token(req, state: state) else { return Self.unauthorized() }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            guard Self.projectMatches(ctx, token: token) else { return Self.projectForbidden(ctx) }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let backups = await state.listBackups(projectID: token.projectID, limit: limit, marker: marker)
            let items = backups.map { Self.backupJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"backups":[\(items)]}
            """)
        }

        router.get("\(base)/:projectId/backups") { req, ctx in
            guard let token = await Self.token(req, state: state) else { return Self.unauthorized() }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            guard Self.projectMatches(ctx, token: token) else { return Self.projectForbidden(ctx) }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let backups = await state.listBackups(projectID: token.projectID, limit: limit, marker: marker)
            let items = backups.map { Self.backupJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"backups":[\(items)]}
            """)
        }

        router.get("\(base)/:projectId/backups/:id") { req, ctx in
            guard let token = await Self.token(req, state: state) else { return Self.unauthorized() }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            guard Self.projectMatches(ctx, token: token) else { return Self.projectForbidden(ctx) }
            let id = ctx.parameters.get("id") ?? ""
            guard let backup = await state.getBackup(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Backup \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"backup":\(Self.backupJSON(backup))}
            """)
        }

        router.post("\(base)/:projectId/backups") { req, ctx in
            guard let token = await Self.token(req, state: state) else { return Self.unauthorized() }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            guard Self.projectMatches(ctx, token: token) else { return Self.projectForbidden(ctx) }
            let body = try await Self.readBody(req)
            let backupBody = Self.objectForKey("backup", in: body) ?? body
            let volumeID = Self.extractString("volume_id", from: backupBody) ?? ""
            let name = Self.extractString("name", from: backupBody) ?? ""
            guard let backup = await state.createBackup(projectID: token.projectID, volumeID: volumeID, name: name) else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Volume \(volumeID) could not be found.")
            }
            return Self.jsonResponse(status: .created, body: """
            {"backup":\(Self.backupJSON(backup))}
            """)
        }

        router.delete("\(base)/:projectId/backups/:id") { req, ctx in
            guard let token = await Self.token(req, state: state) else { return Self.unauthorized() }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            guard Self.projectMatches(ctx, token: token) else { return Self.projectForbidden(ctx) }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteBackup(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Backup \(id) could not be found.")
            }
            return Response(status: .noContent)
        }

        router.post("\(base)/:projectId/backups/:id/restore") { req, ctx in
            guard let token = await Self.token(req, state: state) else { return Self.unauthorized() }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            guard Self.projectMatches(ctx, token: token) else { return Self.projectForbidden(ctx) }
            let id = ctx.parameters.get("id") ?? ""
            guard let vol = await state.restoreBackup(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Backup \(id) could not be found.")
            }
            return Self.jsonResponse(status: .created, body: """
            {"volume":\(Self.volumeJSON(vol))}
            """)
        }

        // MARK: - Quotas
        //
        // Deliberately NOT project-prefixed. Cinder's api-ref documents quota
        // sets as `GET /v3/{admin_project_id}/os-quota-sets/{project_id}`
        // (api-ref/source/v3/quota-sets.inc), and the controller authorizes with
        // `volume_extension:quotas:show`, whose default is
        // `rule:system_reader_or_project_reader` scoped to the TARGET project
        // (cinder/policies/quotas.py) — a project member reads its OWN quota by
        // naming itself as the target, which is what the client does
        // (`GET os-quota-sets/{token.project.id}`). Cinder's extension router
        // registers the collection without a `{project_id}` prefix, so the
        // client's path is correct and needs no change.

        router.get("\(base)/os-quota-sets/:projectId") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  await state.validateToken(tokenID) != nil else {
                return Self.unauthorized()
            }
            guard req.headers[FakeHeaders.openstackAPIVersion] != nil else {
                return Self.cinderError(status: .badRequest, type: "badRequest", message: "Missing OpenStack-API-Version header.")
            }
            let projectId = ctx.parameters.get("projectId") ?? ""
            _ = projectId
            // Cinder v3 quota response: {"quota_set": {...}}
            return Self.jsonResponse(status: .ok, body: """
            {"quota_set":{"volumes":10,"gigabytes":1000,"snapshots":10}}
            """)
        }
    }

    // MARK: - Auth / project scoping

    /// Validated token for the request, or nil when unauthenticated.
    static func token(_ req: Request, state: FakeState) async -> FakeState.FakeToken? {
        guard let tokenID = req.headers[FakeHeaders.xAuthToken] else { return nil }
        return await state.validateToken(tokenID)
    }

    /// Cinder's `{project_id}` path segment must name the token's own project.
    static func projectMatches(_ ctx: BasicRequestContext, token: FakeState.FakeToken) -> Bool {
        (ctx.parameters.get("projectId") ?? "") == token.projectID
    }

    static func projectForbidden(_ ctx: BasicRequestContext) -> Response {
        forbidden(message: "Not allowed to access project \(ctx.parameters.get("projectId") ?? "").")
    }

    static func forbidden(message: String) -> Response {
        cinderError(status: .forbidden, type: "forbidden", message: message)
    }

    // MARK: - JSON builders

    static func volumeJSON(_ vol: FakeState.FakeVolume) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(vol.id)\"")
        parts.append("\"name\":\"\(vol.name)\"")
        parts.append("\"status\":\"\(vol.status)\"")
        parts.append("\"size\":\(vol.size)")
        parts.append("\"volume_type\":\"\(vol.volumeType)\"")
        let az = vol.availabilityZone.map { "\"\($0)\"" } ?? "null"
        parts.append("\"availability_zone\":\(az)")
        parts.append("\"bootable\":\(vol.bootable)")
        parts.append("\"multiattach\":\(vol.multiattach)")
        if let meta = vol.metadata, !meta.isEmpty {
            let m = meta.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
            parts.append("\"metadata\":{\(m)}")
        }
        let src = vol.sourceVolumeID.map { "\"\($0)\"" } ?? "null"
        parts.append("\"source_vol_id\":\(src)")
        let img = vol.imageID.map { "\"\($0)\"" } ?? "null"
        parts.append("\"image_id\":\(img)")
        let attachments = vol.attachments.map { a in
            "{\"id\":\"\(a.id)\",\"server_id\":\"\(a.serverID ?? "")\",\"volume_id\":\"\(a.volumeID)\",\"device\":\"\(a.device)\"}"
        }.joined(separator: ",")
        parts.append("\"attachments\":[\(attachments)]")
        parts.append("\"created_at\":\"\(vol.created)\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// Cinder's volume-type view builder (`cinder/api/views/types.py`) trims a
    /// list entry to `id`, `name`, `is_public`, `extra_specs`, `description`.
    static func volumeTypeJSON(_ vt: FakeState.FakeVolumeType) -> String {
        let specs = (vt.extraSpecs ?? [:]).map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        return """
        {"id":"\(vt.id)","name":"\(vt.name)","description":"\(vt.name) volume type","is_public":true,"extra_specs":{\(specs)}}
        """
    }

    static func snapshotJSON(_ snap: FakeState.FakeSnapshot) -> String {
        return """
        {"id":"\(snap.id)","name":"\(snap.name)","status":"\(snap.status)","volume_id":"\(snap.volumeID)","size":\(snap.size),"created_at":"\(snap.created)"}
        """
    }

    static func backupJSON(_ backup: FakeState.FakeBackup) -> String {
        return """
        {"id":"\(backup.id)","name":"\(backup.name)","status":"\(backup.status)","volume_id":"\(backup.volumeID)","size":\(backup.size),"created_at":"\(backup.created)"}
        """
    }

    // MARK: - Helpers

    static func readBody(_ req: Request) async throws -> String {
        var data = ""
        for try await buffer in req.body {
            data += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        }
        return data
    }

    static func queryParam(_ name: String, from req: Request) -> String? {
        req.uri.queryParameters[Substring(name)].map { String($0) }
    }

    static func objectForKey(_ key: String, in json: String) -> String? {
        let pattern = "\"\(key)\":"
        guard let start = json.range(of: pattern) else { return nil }
        let afterColon = json[start.upperBound...]
        guard let open = afterColon.firstIndex(of: "{") else { return nil }
        var depth = 0
        for (idx, ch) in afterColon.enumerated() {
            _ = idx
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let end = afterColon.index(afterColon.startIndex, offsetBy: idx)
                    return String(afterColon[open...end])
                }
            }
        }
        return nil
    }

    static func extractString(_ key: String, from json: String) -> String? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if afterColon.hasPrefix("\"") {
            let rest = afterColon.dropFirst()
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[rest.startIndex..<close])
        }
        return nil
    }

    static func extractInt(_ key: String, from json: String) -> Int? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        var numStr = ""
        for ch in afterColon {
            if ch == "," || ch == "}" || ch == "]" { break }
            numStr.append(ch)
        }
        return Int(numStr)
    }

    static func extractBool(_ key: String, from json: String) -> Bool? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if afterColon.hasPrefix("true") { return true }
        if afterColon.hasPrefix("false") { return false }
        return nil
    }

    // MARK: - Responses

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: body))
        )
    }

    static func unauthorized() -> Response {
        cinderError(status: .unauthorized, type: "forbidden", message: "Unauthorized")
    }

    static func itemNotFound(message: String) -> Response {
        cinderError(status: .notFound, type: "itemNotFound", message: message)
    }

    static func cinderError(status: HTTPResponse.Status, type: String, message: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: """
            {"\(type)":{"message":"\(message)"}}
            """))
        )
    }
}
