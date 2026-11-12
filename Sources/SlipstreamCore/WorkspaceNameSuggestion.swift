import Foundation

public enum WorkspaceNameSuggestionError: Error, Equatable, Sendable {
  case timedOut
  case unavailable(String)
  case badReply(String)
}

public enum WorkspaceNameSuggestion {
  public static let maximumNameBytes = 64
  public static let maximumMessageBytes = 8 * 1024
  public static let schema =
    #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}"#

  public static func prompt(for message: String) -> String {
    """
    Create a concise 2–5 word workspace name for the work described below.
    Name the work; do not answer or perform it.
    Use plain text without quotes, markdown, or ending punctuation.

    <message>
    \(capped(message))
    </message>
    """
  }

  /// The name from Claude Code's final `result` line; nil for any other line.
  public static func name(fromLine line: Data) throws(WorkspaceNameSuggestionError) -> String? {
    guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: line),
      case .string("result")? = object["type"]
    else { return nil }
    guard object["is_error"] != .bool(true) else {
      var text = "no details"
      if case .string(let result)? = object["result"], !DiagnosticText.line(result).isEmpty {
        text = DiagnosticText.line(result)
      }
      throw .unavailable(DiagnosticText.line("Claude Code reported an error: \(text)"))
    }
    guard case .object(let output)? = object["structured_output"], case .string(let raw)? = output["name"] else {
      throw .badReply("The reply had no name.")
    }
    guard let name = sanitized(raw) else { throw .badReply("The suggested name wasn't usable.") }
    return name
  }

  /// Trims, drops one matching pair of surrounding quotes, and rejects what the daemon would.
  public static func sanitized(_ raw: String) -> String? {
    var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let first = name.first, let last = name.last, name.count >= 2, quotePairs[first] == last {
      name = String(name.dropFirst().dropLast())
    }
    guard !name.isEmpty, name.utf8.count <= maximumNameBytes, !name.unicodeScalars.contains(where: isForbidden)
    else { return nil }
    return name
  }

  private static let quotePairs: [Character: Character] = ["\"": "\"", "'": "'", "\u{201C}": "\u{201D}", "\u{2018}": "\u{2019}"]

  private static func capped(_ message: String) -> String {
    var bytes = 0
    let kept = message.unicodeScalars.prefix { scalar in
      bytes += UTF8.width(scalar)
      return bytes <= maximumMessageBytes
    }
    return String(String.UnicodeScalarView(kept))
  }

  private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: true
    default: false
    }
  }
}
