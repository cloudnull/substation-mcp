import Testing
import Foundation
import Logging
@testable import OpenStackMCPServer

// MARK: - Redaction (spec §12)

@Test("Redactor drops values for sensitive keys")
func redactorDropsSensitiveKeys() {
    let json = """
    {"password":"hunter2","username":"alice","nested":{"adminPass":"p@ss","safe":"keep"},"user_data":"blob"}
    """
    let out = Redactor.redact(json)
    #expect(out.contains("\"password\":\"[REDACTED]\""))
    #expect(out.contains("\"adminPass\":\"[REDACTED]\""))
    #expect(out.contains("\"user_data\":\"[REDACTED]\""))
    // Non-sensitive keys are untouched.
    #expect(out.contains("\"username\":\"alice\""))
    #expect(out.contains("\"safe\":\"keep\""))
    // The secret values are gone.
    #expect(!out.contains("hunter2"))
    #expect(!out.contains("p@ss"))
}

@Test("Redactor drops auth headers and is case-insensitive on keys")
func redactorDropsAuthHeadersCaseInsensitive() {
    let json = #"{"Authorization":"Bearer tok-123","X-Auth-Token":"tok-123","other":"x"}"#
    let out = Redactor.redact(json)
    #expect(out.contains("\"Authorization\":\"[REDACTED]\""))
    #expect(out.contains("\"X-Auth-Token\":\"[REDACTED]\""))
    #expect(!out.contains("tok-123"))
    #expect(out.contains("\"other\":\"x\""))
}

@Test("Redactor handles nested arrays of objects")
func redactorHandlesNestedArrays() {
    let json = #"{"requests":[{"password":"s1"},{"name":"ok"}],"top":"v"}"#
    let out = Redactor.redact(json)
    #expect(out.contains("\"password\":\"[REDACTED]\""))
    #expect(!out.contains("s1"))
    #expect(out.contains("\"name\":\"ok\""))
    #expect(out.contains("\"top\":\"v\""))
}

@Test("Redactor returns non-JSON input unchanged")
func redactorPassesThroughNonJSON() {
    let plain = "no secrets here, just text"
    #expect(Redactor.redact(plain) == plain)
}

@Test("Redactor redacts a token value in the payload dict")
func redactorRedactsTokenPayloadDict() {
    // Spec: "any field named ... token". A credential body carrying a `token`
    // field must be masked.
    let json = #"{"token":"faketon","region":"R1"}"#
    let out = Redactor.redact(json)
    #expect(out.contains("\"token\":\"[REDACTED]\""))
    #expect(!out.contains("faketon"))
    #expect(out.contains("\"region\":\"R1\""))
}

 @Test("Redactor redacts camelCase/snake_case token-id key variants")
 func redactorRedactsTokenIDVariants() {
     // A Keystone token ID *is* the credential. The login-page log used the
     // key `tokenID` (camelCase), which lowercases to `tokenid` — that variant
     // was NOT in sensitiveKeys, so the full token leaked into the logs. All
     // token-id key spellings must be masked, not just the bare `token`.
     for json in [
         #"{"tokenID":"gAAAAAB-secret-keystone-token","project":"p1"}"#,
         #"{"token_id":"gAAAAAB-secret-keystone-token","project":"p1"}"#,
         #"{"os_auth_token":"gAAAAAB-secret-keystone-token"}"#,
     ] {
         let out = Redactor.redact(json)
         #expect(!out.contains("gAAAAAB-secret-keystone-token"),
                 "token id leaked in redacted output: \(out)")
         #expect(out.contains("[REDACTED]"),
                 "expected a redacted value: \(out)")
     }
 }

// MARK: - JSON log handler redacts metadata before it reaches the sink

@Test("JSON log handler redacts sensitive metadata before writing")
func jsonHandlerRedactsMetadata() {
    let handler = RedactingJSONLogHandler(label: "test", sink: .standardOutput)
    let logger = Logger(label: "test") { _ in handler }

    logger.info(
        "minted token",
        metadata: [
            "token": "fake-tok-0001",
            "X-Auth-Token": "fake-tok-0001",
            "project": "proj-one",
        ]
    )

    let line = handler.format(
        level: .info,
        message: "minted token",
        metadata: [
            "token": "fake-tok-0001",
            "X-Auth-Token": "fake-tok-0001",
            "project": "proj-one",
        ]
    )
    // The secret never appears in the formatted line.
    #expect(!line.contains("fake-tok-0001"))
    #expect(line.contains("[REDACTED]"))
    // Non-sensitive metadata survives.
    #expect(line.contains("\"project\":\"proj-one\""))
    // The message survives.
    #expect(line.contains("minted token"))
}

@Test("JSON log handler emits a parseable JSON line")
func jsonHandlerEmitsParseableJSON() {
    let handler = RedactingJSONLogHandler(label: "test", sink: .standardOutput)
    let line = handler.format(
        level: .info,
        message: "hello world",
        metadata: ["cloud": "sat0", "tool": "os_list"]
    )
    let data = Data(line.utf8)
    let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(obj["level"] as? String == "info")
    #expect(obj["logger"] as? String == "test")
    #expect(obj["message"] as? String == "hello world")
    let meta = obj["meta"] as! [String: Any]
    #expect(meta["cloud"] as? String == "sat0")
    #expect(meta["tool"] as? String == "os_list")
    #expect((obj["ts"] as? String)?.isEmpty == false)
}

// MARK: - Logger construction

@Test("makeLogger returns a logger at the requested level")
func makeLoggerLevel() {
    let l = makeLogger(level: "debug", format: "json", sink: .standardOutput)
    #expect(l.logLevel == .debug)
    let l2 = makeLogger(level: "error", format: "logfmt", sink: .standardError)
    #expect(l2.logLevel == .error)
    // Unknown level falls back to info.
    let l3 = makeLogger(level: "bogus", format: "json", sink: .standardOutput)
    #expect(l3.logLevel == .info)
}
