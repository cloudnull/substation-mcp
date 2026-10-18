import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
@testable import OpenStackClient
@testable import FakeOpenStack

@Suite("CloudFormationService Tests", .timeLimit(.minutes(2)))
struct CloudFormationServiceTests {
    private static let logger = Logger(label: "test-cfn")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, CloudFormationService, Transport) {
        let handle = try await FakeApp.start()
        let state = handle.state

        guard let fakeToken = await state.mintToken(credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "Failed to mint token")
        }
        let tokenID = fakeToken.id

        let url = handle.keystoneURL.appendingPathComponent("auth/tokens")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let httpStatus = (resp as! HTTPURLResponse).statusCode
        #expect(httpStatus == 200, "Token validation failed: \(httpStatus)")

        let token = try Token.decode(from: data)
        let vt = ValidatedToken(token: token, scopes: [.read, .write])

        let cloud = CloudEntry(
            name: "fake",
            authURL: URL(string: handle.url.absoluteString)!,
            regionName: "RegionOne"
        )
        let cache = Cache(maxEntries: 100)
        let transport = Transport(cloud: cloud, tokenSource: { tokenID }, logger: Self.logger)
        let cfn = CloudFormationService(cloud: cloud, transport: transport, cache: cache, logger: Self.logger)
        return (handle, vt, cfn, transport)
    }

    @Test("CreateStack -> ListStacks -> DescribeStacks -> UpdateStack -> DeleteStack")
    func stackLifecycle() async throws {
        let (handle, vt, cfn, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let region = cfn.region("RegionOne")

        let created = try await region.createStack(vt, CreateCFNStackSpec(
            stackName: "test-stack",
            templateBody: "{\"ROSTemplateFormatVersion\":\"2010-09-09\"}",
            parameters: ["Env": "prod"],
            tags: ["team": "infra"]
        ))
        #expect(created.stackName == "test-stack")
        #expect(!created.stackID.isEmpty)

        let listed = try await region.listStacks(vt)
        #expect(listed.count == 1)
        #expect(listed[0].stackName == "test-stack")
        #expect(listed[0].stackStatus == "CREATE_COMPLETE")

        let described = try await region.describeStacks(vt, nameOrID: "test-stack")
        #expect(described.count == 1)
        #expect(described[0].parameters.first?.key == "Env")
        #expect(described[0].parameters.first?.value == "prod")
        #expect(described[0].tags.first?.key == "team")

        let updated = try await region.updateStack(vt, nameOrID: "test-stack", templateBody: "{\"ROSTemplateFormatVersion\":\"2010-09-09\"}", parameters: ["Env": "staging"])
        #expect(updated.stackID == created.stackID)
        let afterUpdate = try await region.describeStacks(vt, nameOrID: "test-stack")
        #expect(afterUpdate[0].stackStatus == "UPDATE_COMPLETE")
        #expect(afterUpdate[0].parameters.first?.value == "staging")

        try await region.deleteStack(vt, nameOrID: "test-stack")
        let empty = try await region.listStacks(vt)
        #expect(empty.isEmpty)
    }

    @Test("DescribeStacks for a missing stack maps AWS ValidationError to 400")
    func describeMissing() async throws {
        let (handle, vt, cfn, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let region = cfn.region("RegionOne")

        do {
            _ = try await region.describeStacks(vt, nameOrID: "nope")
            Issue.record("Expected 400 for missing stack")
        } catch let e as OpenStackError {
            #expect(e.status == 400)
            #expect(e.message.contains("does not exist"))
        }
    }

    @Test("duplicate CreateStack names are rejected")
    func duplicateCreate() async throws {
        let (handle, vt, cfn, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let region = cfn.region("RegionOne")

        _ = try await region.createStack(vt, CreateCFNStackSpec(stackName: "dup", templateBody: "{}"))
        do {
            _ = try await region.createStack(vt, CreateCFNStackSpec(stackName: "dup", templateBody: "{}"))
            Issue.record("Expected 400 for duplicate stack name")
        } catch let e as OpenStackError {
            #expect(e.status == 400)
        }
    }

    @Test("ValidateTemplate returns the template parameter keys")
    func validateTemplate() async throws {
        let (handle, vt, cfn, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let region = cfn.region("RegionOne")

        let template = """
        {"ROSTemplateFormatVersion":"2010-09-09","Parameters":{"KeyName":{"Type":"String"},"ImageId":{"Type":"String"}}}
        """
        let keys = try await region.validateTemplate(vt, templateBody: template)
        #expect(keys == ["ImageId", "KeyName"])
    }

    @Test("XML helpers extract members and unescape entities")
    func xmlHelpers() throws {
        let xml = "<Stacks><member><StackName>a&amp;b</StackName></member><member><StackName>c</StackName></member></Stacks>"
        let inner = CloudFormationRegion.xmlValueBlock(xml, container: "Stacks") ?? ""
        #expect(CloudFormationRegion.xmlValue(inner, tag: "StackName") == "a&b")
        #expect(CloudFormationRegion.xmlMember(inner, tag: "member", index: 2)?.contains(">c<") == true)
        #expect(CloudFormationRegion.xmlMember(inner, tag: "member", index: 3) == nil)
    }
}
