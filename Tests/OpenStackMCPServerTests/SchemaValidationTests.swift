import Testing
import Foundation
import OpenStackClient
import OpenStackMCPServer

@Suite("Schema Validation Tests")
struct SchemaValidationTests {
    let catalog = ResourceCatalog.phase1()

    // MARK: - Validation issue fields (spec §8.2)

    @Test("validation issue has path, expected, found, fragment")
    func issueFields() {
        let d = catalog.descriptor("server")!
        let schema = d.createSchema!
        let bad = JSONValue.object(["flavor": .integer(1), "image": .string("img")])
        let issues = schema.validate(bad)

        // Should have issues for missing name and wrong flavor type
        #expect(issues.count >= 2, "Expected at least 2 issues, got \(issues.count)")

        let flavorIssue = issues.first { $0.path == "$.flavor" }
        #expect(flavorIssue != nil, "Expected flavor issue")
        #expect(flavorIssue?.expected == "string")
        #expect(flavorIssue?.found == "integer")
        #expect(!flavorIssue!.fragment.isEmpty, "Fragment should not be empty")
        #expect(flavorIssue!.fragment.contains("string"), "Fragment should mention the expected type")

        let nameIssue = issues.first { $0.path == "$.name" }
        #expect(nameIssue != nil, "Expected missing name issue")
        #expect(nameIssue?.found == "missing")
    }

    @Test("unknown property rejected when additionalProperties is false")
    func unknownPropertyRejected() {
        let schema = JSONSchema(
            type: "object",
            properties: ["name": JSONSchema(type: "string")],
            required: ["name"],
            additionalProperties: false
        )
        let bad = JSONValue.object([
            "name": .string("test"),
            "unknown_field": .string("bad")
        ])
        let issues = schema.validate(bad)
        #expect(issues.contains { $0.path == "$.unknown_field" }, "Expected unknown property issue")
    }

    @Test("valid spec yields zero issues")
    func validSpec() {
        let d = catalog.descriptor("server")!
        let schema = d.createSchema!
        let good = JSONValue.object([
            "name": .string("web-1"),
            "flavor": .string("m1.small"),
            "image": .string("ubuntu-24.04")
        ])
        let issues = schema.validate(good)
        #expect(issues.isEmpty, "Expected no issues, got: \(issues.map(\.path))")
    }

    @Test("enum validation: wrong value rejected")
    func enumValidation() {
        let schema = JSONSchema(
            type: "object",
            properties: [
                "visibility": JSONSchema(type: "string", enumValues: [.string("public"), .string("private")])
            ]
        )
        let bad = JSONValue.object(["visibility": .string("secret")])
        let issues = schema.validate(bad)
        #expect(issues.contains { $0.path == "$.visibility" && $0.expected.contains("one of") }, "Expected enum issue")
    }

    // MARK: - Filter validation

    @Test("unknown list filter rejected with known list")
    func unknownFilterRejected() {
        let d = catalog.descriptor("server")!
        do {
            try checkFilters(descriptor: d, filters: ["bogus_filter": "value"])
            Issue.record("Expected error for unknown filter")
        } catch let error as OpenStackError {
            #expect(error.status == 400)
            #expect(error.message.contains("bogus_filter"), "Message should mention the unknown filter")
            #expect(error.message.contains("status"), "Message should list known filters including 'status'")
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("known list filter accepted")
    func knownFilterAccepted() throws {
        let d = catalog.descriptor("server")!
        try checkFilters(descriptor: d, filters: ["status": "ACTIVE", "name": "web"])
        // No throw means pass
    }

    @Test("empty filters always accepted")
    func emptyFiltersAccepted() throws {
        let d = catalog.descriptor("server")!
        try checkFilters(descriptor: d, filters: [:])
    }

    // MARK: - Projection

    @Test("projection keeps only named top-level fields")
    func projection() {
        let raw: [String: JSONValue] = [
            "id": .string("srv-0001"),
            "name": .string("web-1"),
            "status": .string("ACTIVE"),
            "flavor": .string("m1.small"),
            "addresses": .object([:]),
            "created": .string("2026-01-01T00:00:00Z"),
            "extra_field": .string("should be dropped")
        ]
        let fields = ["id", "name", "status", "flavor", "addresses", "created"]
        let projected = project(raw, fields)

        #expect(projected.count == 6, "Expected 6 fields, got \(projected.count)")
        #expect(projected["id"]?.stringValue == "srv-0001")
        #expect(projected["name"]?.stringValue == "web-1")
        #expect(projected["extra_field"] == nil, "extra_field should be dropped")
    }

    @Test("projection with missing fields skips them")
    func projectionMissingFields() {
        let raw: [String: JSONValue] = [
            "id": .string("net-1"),
            "name": .string("ext-net")
        ]
        let fields = ["id", "name", "status", "mtu"]
        let projected = project(raw, fields)
        #expect(projected.count == 2, "Expected 2 fields (only id and name present), got \(projected.count)")
        #expect(projected["status"] == nil)
        #expect(projected["mtu"] == nil)
    }

    // MARK: - Error paragraph

    @Test("error paragraph contains status, request ID, and hint")
    func errorParagraphContent() {
        let err = OpenStackError(
            service: "nova",
            status: 403,
            code: "forbidden",
            message: "Policy does not allow compute:create",
            requestID: "req-abc-123",
            hint: "the application credential's access rules do not allow this operation"
        )
        let paragraph = errorParagraph(err, what: "Creating server")
        #expect(paragraph.contains("Creating server failed"), "Should state what failed")
        #expect(paragraph.contains("HTTP 403"), "Should include HTTP status")
        #expect(paragraph.contains("nova"), "Should include service")
        #expect(paragraph.contains("Policy does not allow"), "Should include OpenStack message")
        #expect(paragraph.contains("req-abc-123"), "Should include request ID")
        #expect(paragraph.contains("Hint:"), "Should include hint")
    }

    @Test("error paragraph redacts secrets")
    func errorParagraphRedacts() {
        let err = OpenStackError(
            service: "keystone",
            status: 401,
            code: "unauthorized",
            message: "The request you sent has failed authentication. secret=abc123password token=xyz789",
            requestID: nil
        )
        let paragraph = errorParagraph(err, what: "Authenticating")
        #expect(!paragraph.contains("abc123password"), "Secret should be redacted")
        #expect(!paragraph.contains("xyz789"), "Token should be redacted")
        #expect(paragraph.contains("[REDACTED]"), "Should contain [REDACTED]")
    }

    @Test("error paragraph without request ID or hint")
    func errorParagraphMinimal() {
        let err = OpenStackError(
            service: "neutron",
            status: 404,
            code: "itemNotFound",
            message: "Network not found."
        )
        let paragraph = errorParagraph(err, what: "Getting network")
        #expect(paragraph.contains("Getting network failed"))
        #expect(paragraph.contains("HTTP 404"))
        #expect(paragraph.contains("Network not found."))
        #expect(!paragraph.contains("request ID"), "Should not mention request ID when absent")
        #expect(!paragraph.contains("Hint:"), "Should not mention hint when absent")
    }

    // MARK: - Redaction unit tests

    @Test("redact handles secret= pattern")
    func redactSecret() {
        let input = "failed: secret=mySuperSecret123"
        let output = redact(input)
        #expect(!output.contains("mySuperSecret123"))
        #expect(output.contains("[REDACTED]"))
    }

    @Test("redact handles password= pattern")
    func redactPassword() {
        let input = "password=hunter2"
        let output = redact(input)
        #expect(!output.contains("hunter2"))
        #expect(output.contains("[REDACTED]"))
    }

    @Test("redact handles token= pattern")
    func redactToken() {
        let input = "token=abc123def456"
        let output = redact(input)
        #expect(!output.contains("abc123def456"))
        #expect(output.contains("[REDACTED]"))
    }

    @Test("redact leaves non-secret text unchanged")
    func redactNoSecret() {
        let input = "Network not found. Please check the ID."
        let output = redact(input)
        #expect(output == input, "Non-secret text should be unchanged")
    }
}
