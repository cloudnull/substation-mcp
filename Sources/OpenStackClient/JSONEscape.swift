import Foundation

/// Escapes a string for embedding inside a JSON string literal.
///
/// Several service request bodies in this module are assembled by string
/// interpolation rather than `JSONEncoder` (microversion-gated or partial-update
/// payloads where only the present keys may be sent). Any caller-visible value —
/// a name, description, URI, property key — can carry `"` or `\`, and
/// unescaped that produces a malformed body the service rejects with a schema
/// error that names neither the offending value nor the escaping problem.
///
/// Control characters are escaped as `\uXXXX`, which is what a JSON parser
/// requires; a raw newline inside a string literal is invalid JSON.
func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            // Remaining C0 controls (e.g. \u{00}, \u{1B}) are invalid inside a
            // JSON string literal and must be \u-escaped.
            if let scalar = ch.unicodeScalars.first, scalar.value < 0x20 {
                out += String(format: "\\u%04X", scalar.value)
            } else {
                out.append(ch)
            }
        }
    }
    return out
}
