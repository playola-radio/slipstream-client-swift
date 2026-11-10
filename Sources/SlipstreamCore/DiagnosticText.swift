import Foundation

/// Text from Claude Code or the daemon, made safe to show: one line, no control characters, at
/// most `limit` characters.
public enum DiagnosticText {
  public static let limit = 500

  public static func line(_ text: String) -> String {
    let line = unwrapped(text)
    return line.count > limit ? line.prefix(limit - 1) + "…" : line
  }

  /// One line with no control characters, at any length.
  public static func unwrapped(_ text: String) -> String {
    let scalars = text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
      if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
      return CharacterSet.controlCharacters.contains(scalar) ? nil : scalar
    }
    return String(String.UnicodeScalarView(scalars)).split(separator: " ").joined(separator: " ")
  }
}
