/// A language the syntax lexer colours. A card resolves it from its file extension and a chat
/// code block from its fence tag, through one alias table. Anything else is drawn flat.
public enum SyntaxLanguage: Equatable, Sendable {
  case swift, typescript, json, yaml, shell, markdown, python, css, html

  public init?(path: String) {
    let name = path.split(separator: "/").last ?? ""
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    self.init(alias: name[name.index(after: dot)...])
  }

  public init?(fenceInfo: String) {
    guard let tag = fenceInfo.split(whereSeparator: \.isWhitespace).first else { return nil }
    self.init(alias: tag)
  }

  private init?(alias: Substring) {
    guard let language = Self.aliases[alias.lowercased()] else { return nil }
    self = language
  }

  private static let aliases: [String: SyntaxLanguage] = [
    "swift": .swift,
    "ts": .typescript, "tsx": .typescript, "js": .typescript, "jsx": .typescript,
    "mjs": .typescript, "cjs": .typescript, "typescript": .typescript, "javascript": .typescript,
    "json": .json,
    "yml": .yaml, "yaml": .yaml,
    "sh": .shell, "bash": .shell, "zsh": .shell,
    "md": .markdown, "markdown": .markdown,
    "py": .python, "python": .python,
    "css": .css,
    "html": .html, "htm": .html,
  ]
}
