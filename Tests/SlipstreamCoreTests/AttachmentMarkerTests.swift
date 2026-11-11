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
      AttachmentMarker.parse("go " + marker),
      AttachmentMarker.Parsed(body: "go", name: "f.md", path: path)
    )
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
