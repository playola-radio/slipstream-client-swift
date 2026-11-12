import CustomDump
import SlipstreamCore
import Testing

struct AttachmentMarkerTests {
  @Test func formatsAndParsesRoundTrip() {
    let path = "/Users/b/Library/Application Support/Slipstream/attachments/U/PR instructions.md"
    let marker = AttachmentMarker.format(name: "PR instructions.md", path: path)

    expectNoDifference(
      marker,
      "@⟦PR instructions.md⟧(/Users/b/Library/Application%20Support/Slipstream/attachments/U/PR%20instructions.md)"
    )
    expectNoDifference(
      AttachmentMarker.parse("Create a PR " + marker),
      AttachmentMarker.Parsed(body: "Create a PR", name: "PR instructions.md", path: path)
    )
  }

  @Test(arguments: [
    "/tmp/a (1)/file.md",
    "/tmp/#notes/file.md",
    "/tmp/100%/file.md",
    "/tmp/café/résumé.md",
    "/tmp/a b/(c) #d %e é.md",
  ])
  func roundTripsAwkwardPaths(path: String) {
    let marker = AttachmentMarker.format(name: "f.md", path: path)
    expectNoDifference(
      AttachmentMarker.segments("go " + marker),
      [.text("go "), .attachment(name: "f.md", path: path)]
    )
  }

  static let a = AttachmentMarker.Segment.attachment(name: "a.md", path: "/tmp/a.md")
  static let b = AttachmentMarker.Segment.attachment(name: "b.md", path: "/tmp/b.md")

  @Test(arguments: [
    ("hi", [.text("hi")]),
    ("😀 é\nline", [.text("😀 é\nline")]),
    ("Create a PR @⟦a.md⟧(/tmp/a.md)", [.text("Create a PR "), a]),
    ("@⟦a.png⟧(/tmp/a.png)", [.attachment(name: "a.png", path: "/tmp/a.png")]),
    ("see @⟦a.md⟧(/tmp/a.md) and @⟦b.md⟧(/tmp/b.md)!", [.text("see "), a, .text(" and "), b, .text("!")]),
    ("@⟦a.md⟧(/tmp/a.md)@⟦b.md⟧(/tmp/b.md)", [a, b]),
    ("go @⟦a.md⟧(tmp/a.md)", [.text("go @⟦a.md⟧(tmp/a.md)")]),
    ("go @⟦a.md⟧(/tmp/%zz.md)", [.text("go @⟦a.md⟧(/tmp/%zz.md)")]),
    ("go @⟦a.md⟧(/tmp/a.md", [.text("go @⟦a.md⟧(/tmp/a.md")]),
    ("go @⟦a.md⟧(/tmp%2Fa.md)", [.text("go @⟦a.md⟧(/tmp%2Fa.md)")]),
    ("x @⟦bad @⟦a.md⟧(/tmp/a.md)", [.text("x @⟦bad "), a]),
  ] as [(String, [AttachmentMarker.Segment])])
  func segmentsSplitAndRoundTrip(input: String, expected: [AttachmentMarker.Segment]) {
    let segments = AttachmentMarker.segments(input)
    expectNoDifference(segments, expected)
    expectNoDifference(AttachmentMarker.text(segments), input)
  }

  @Test func isImageFollowsTheExtension() {
    #expect(AttachmentMarker.Segment.attachment(name: "a.png", path: "/tmp/a.png").isImage)
    #expect(AttachmentMarker.Segment.attachment(name: "b.HEIC", path: "/tmp/b.HEIC").isImage)
    #expect(!AttachmentMarker.Segment.attachment(name: "c.md", path: "/tmp/c.md").isImage)
    #expect(!AttachmentMarker.Segment.text("a.png").isImage)
  }

  @Test(arguments: [
    "Create @⟦a.md⟧(/tmp/a.md) now",
    "one @⟦a.md⟧(/tmp/a.md) @⟦b.md⟧(/tmp/b.md)",
    "go @⟦a.md⟧(tmp/a.md)",
    "go @⟦a.md⟧(/tmp/%zz.md)",
    "go @⟦a.md⟧(/tmp/a.md",
    "go @⟦a⟧b.md⟧(/tmp/a.md)",
    "@⟦a.md⟧(/tmp/a.md)",
  ])
  func rejectsMalformedMarker(text: String) {
    expectNoDifference(AttachmentMarker.parse(text), nil)
  }

  @Test func keepsMultilineBody() {
    expectNoDifference(
      AttachmentMarker.parse("first\nsecond @⟦a.md⟧(/tmp/a.md)"),
      AttachmentMarker.Parsed(body: "first\nsecond", name: "a.md", path: "/tmp/a.md")
    )
  }
}
