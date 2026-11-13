import CustomDump
import SlipstreamCore
import Testing

struct SyntaxLanguageTests {
  static let aliases: [(String, SyntaxLanguage)] = [
    ("swift", .swift),
    ("ts", .typescript), ("tsx", .typescript), ("js", .typescript), ("jsx", .typescript),
    ("mjs", .typescript), ("cjs", .typescript), ("typescript", .typescript),
    ("javascript", .typescript),
    ("json", .json),
    ("yml", .yaml), ("yaml", .yaml),
    ("sh", .shell), ("bash", .shell), ("zsh", .shell),
    ("md", .markdown), ("markdown", .markdown),
    ("py", .python), ("python", .python),
    ("css", .css),
    ("html", .html), ("htm", .html),
  ]

  @Test(arguments: aliases)
  func aliasResolvesAsPathExtension(alias: String, language: SyntaxLanguage) {
    expectNoDifference(SyntaxLanguage(path: "dir/file.\(alias)"), language)
  }

  @Test(arguments: aliases)
  func aliasResolvesAsFenceTag(alias: String, language: SyntaxLanguage) {
    expectNoDifference(SyntaxLanguage(fenceInfo: alias), language)
  }

  @Test(arguments: [
    ("src/API/Create-User.TSX", SyntaxLanguage.typescript),
    ("types.d.ts", .typescript),
  ])
  func pathUsesTheLastExtensionCaseInsensitively(path: String, language: SyntaxLanguage) {
    expectNoDifference(SyntaxLanguage(path: path), language)
  }

  @Test(arguments: ["Makefile", "Dockerfile", ".zshrc", "notes.txt", "infra/nginx.conf"])
  func unsupportedPathIsFlat(path: String) {
    expectNoDifference(SyntaxLanguage(path: path), nil)
  }

  @Test(arguments: [("Swift", SyntaxLanguage.swift), ("python title=x.py", .python)])
  func fenceUsesTheFirstWordCaseInsensitively(info: String, language: SyntaxLanguage) {
    expectNoDifference(SyntaxLanguage(fenceInfo: info), language)
  }

  @Test(arguments: ["", "console", "text", "diff"])
  func unsupportedFenceIsFlat(info: String) {
    expectNoDifference(SyntaxLanguage(fenceInfo: info), nil)
  }
}
