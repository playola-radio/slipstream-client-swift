import Foundation

public enum Redaction {
  public static func redacted(_ text: String) -> String {
    redactions.reduce(text) { text, redaction in
      redaction.pattern.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: redaction.template)
    }
  }

  private static let redactions: [(pattern: NSRegularExpression, template: String)] = [
    (try! NSRegularExpression(pattern: #"("token"\s*:\s*)"(?:[^"\\]|\\.)*""#), #"$1"<redacted>""#),
    (
      try! NSRegularExpression(
        pattern: #"(token\\*["']?\s*[:=]?\s*\\*["']?|Bearer\s+)[A-Za-z0-9_\-./+=]{32,}"#, options: .caseInsensitive),
      "$1<redacted>"
    ),
  ]
}
