import Foundation
import Logging

// MARK: - Logger construction (spec §12)

/// The output stream a logger writes to.
public enum LogSink: Sendable {
    case standardOutput
    case standardError
}

/// Build a `Logger` for a given level + format, routing to the right stream.
///
/// - `format == "json"` → JSON records (the default, per spec §12).
/// - any other value (`"logfmt"`, `"pretty"`) → the built-in stream handler.
///
/// `sink` selects the destination: `serve` writes to stdout, `stdio` to
/// stderr (so JSON never pollutes the MCP JSON-RPC framing on the pipe).
public func makeLogger(
    level: String,
    format: String,
    sink: LogSink = .standardOutput,
    label: String = "substation-mcp"
) -> Logger {
    let logLevel: Logger.Level
    switch level.lowercased() {
    case "trace": logLevel = .trace
    case "debug": logLevel = .debug
    case "warning": logLevel = .warning
    case "error": logLevel = .error
    case "critical": logLevel = .critical
    case "info", "notice", "": logLevel = .info
    default: logLevel = .info
    }

    var logger = Logger(label: label)
    logger.logLevel = logLevel

    // The built-in `StreamLogHandler` writes plain `level [label] message`
    // lines to the chosen stream. For JSON we wrap it with a handler that
    // serializes each record (metadata + message) as a single JSON line and
    // runs the line through ``Redactor`` so secrets never reach the sink.
    if format.lowercased() == "json" {
        logger.handler = RedactingJSONLogHandler(
            label: label,
            sink: sink,
            logLevel: logLevel
        )
    }
    return logger
}

/// A `LogHandler` that writes one JSON object per record to a stream, with the
/// record's metadata and message run through ``Redactor`` first (spec §12).
///
/// The handler is self-contained (no `LoggingSystem.bootstrap` needed) so it
/// can be constructed directly and unit-tested with a `CapturingLogHandler`-
/// style assertion on the formatted line.
public struct RedactingJSONLogHandler: LogHandler, Sendable {
    public let id: Logger.MetadataValue
    public var metadata: Logger.Metadata
    public var logLevel: Logger.Level

    private let label: String
    private let sink: LogSink

    public init(
        label: String = "substation-mcp",
        sink: LogSink = .standardOutput,
        logLevel: Logger.Level = .info
    ) {
        self.id = .string("json")
        self.metadata = Logger.Metadata()
        self.logLevel = logLevel
        self.label = label
        self.sink = sink
    }

    public subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set {
            if let newValue {
                metadata[key] = newValue
            } else {
                metadata.removeValue(forKey: key)
            }
        }
    }

    public func log(event: LogEvent) {
        // swift-log already enforces the level filter for this handler.
        let merged = self.metadata.merging(event.metadata ?? [:]) { _, new in new }
        let payload = format(level: event.level, message: event.message, metadata: merged)
        writeLine(payload)
    }

    /// Compose the redacted JSON line for a record.
    func format(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata
    ) -> String {
        var metaStrings: [String: String] = [:]
        for (k, v) in metadata {
            metaStrings[k] = v.description
        }
        let metaJSON = Redactor.redact(jsonEncode(metaStrings))
        let line =
            "{"
            + "\"level\":\"" + jsonEscape(levelLabel(level)) + "\","
            + "\"logger\":\"" + jsonEscape(label) + "\","
            + "\"ts\":\"" + jsonEscape(iso8601(Date())) + "\","
            + "\"message\":\"" + jsonEscape(message.description) + "\","
            + "\"meta\":" + metaJSON
            + "}"
        return line
    }

    private func jsonEncode(_ dict: [String: String]) -> String {
        guard !dict.isEmpty else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    private func levelLabel(_ level: Logger.Level) -> String {
        switch level {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .warning: return "warning"
        case .error: return "error"
        case .critical: return "critical"
        }
    }

    private func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func writeLine(_ line: String) {
        let data = Data((line + "\n").utf8)
        switch sink {
        case .standardOutput:
            FileHandle.standardOutput.write(data)
        case .standardError:
            FileHandle.standardError.write(data)
        }
    }
}
