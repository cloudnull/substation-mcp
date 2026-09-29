import Testing
@testable import OpenStackClient

struct ScaffoldTests {
    @Test func versionIsPinned() {
        #expect(openStackClientVersion == "0.1.0")
    }
}
