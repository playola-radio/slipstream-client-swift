import Foundation

public enum AppLogLevel: String, Sendable {
  case info = "INFO"
  case error = "ERROR"
}

public enum AppLogLine {
  /// `2026-11-12T18:03:04.123Z ERROR [daemon] first line`; later lines of a multi-line message are indented two spaces.
  public static func format(date: Date, level: AppLogLevel, category: String, message: String) -> String {
    let trimmed = Redaction.redacted(message).trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
    let body = lines.enumerated().map { $0.offset == 0 ? String($0.element) : "  \($0.element)" }.joined(separator: "\n")
    return "\(date.formatted(timestamp)) \(level.rawValue) [\(category)] \(body)\n"
  }

  private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
