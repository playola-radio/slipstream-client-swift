import Foundation

/// The `@⟦name⟧(path)` marker that ends a chat message to point at an attached file.
public enum AttachmentMarker {
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
