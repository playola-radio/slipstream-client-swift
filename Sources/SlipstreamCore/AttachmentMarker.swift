import Foundation
import UniformTypeIdentifiers

/// The `@⟦name⟧(path)` marker that points a chat message at an attached file.
public enum AttachmentMarker {
  public enum Segment: Equatable, Sendable {
    case text(String)
    case attachment(name: String, path: String)

    public var isImage: Bool {
      guard case .attachment(_, let path) = self,
        let type = UTType(filenameExtension: (path as NSString).pathExtension)
      else { return false }
      return type.conforms(to: .image)
    }
  }

  public struct Parsed: Equatable, Sendable {
    public var body: String
    public var name: String
    public var path: String

    public init(body: String, name: String, path: String) {
      self.body = body
      self.name = name
      self.path = path
    }
  }

  private static let allowed = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/"
  )

  public static func format(name: String, path: String) -> String {
    let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    return "@⟦\(name)⟧(\(encoded))"
  }

  /// Every well-formed marker becomes an `.attachment`; everything else stays verbatim `.text`.
  public static func segments(_ text: String) -> [Segment] {
    var segments: [Segment] = []
    var start = text.startIndex
    for match in text.matches(of: /@⟦([^⟦⟧\n]+)⟧\(([^()\s]+)\)/) {
      guard let path = String(match.2).removingPercentEncoding,
        path.hasPrefix("/"),
        format(name: String(match.1), path: path) == match.0
      else { continue }
      if start < match.range.lowerBound { segments.append(.text(String(text[start..<match.range.lowerBound]))) }
      segments.append(.attachment(name: String(match.1), path: path))
      start = match.range.upperBound
    }
    if start < text.endIndex { segments.append(.text(String(text[start...]))) }
    return segments
  }

  public static func text(_ segments: [Segment]) -> String {
    segments.map { segment in
      switch segment {
      case .text(let text): text
      case .attachment(let name, let path): format(name: name, path: path)
      }
    }
    .joined()
  }

  /// Accepts exactly one marker, at the very end of `text`, after a non-empty body.
  public static func parse(_ text: String) -> Parsed? {
    let pattern = /(.*\S)\s@⟦([^⟦⟧\n]+)⟧\(([^()\s]+)\)/.dotMatchesNewlines()
    guard let match = text.wholeMatch(of: pattern),
      !match.1.contains("@⟦"),
      let path = String(match.3).removingPercentEncoding,
      path.hasPrefix("/")
    else { return nil }
    return Parsed(body: String(match.1), name: String(match.2), path: path)
  }
}
