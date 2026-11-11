import CustomDump
import Foundation
import Testing

@testable import SlipstreamViewer

struct AttachmentClientTests {
  func makeBase() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "attachments-\(UUID().uuidString)")
  }

  @Test func writeCreatesFileUnderAFreshFolder() throws {
    let base = makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let client = AttachmentClient.live(base: base)

    let file = try client.write("PR instructions.md", "Do the thing")

    expectNoDifference(file.lastPathComponent, "PR instructions.md")
    #expect(UUID(uuidString: file.deletingLastPathComponent().lastPathComponent) != nil)
    expectNoDifference(file.deletingLastPathComponent().deletingLastPathComponent().path, base.path)
    expectNoDifference(try String(contentsOf: file, encoding: .utf8), "Do the thing")
  }

  @Test func openOfMissingFileNamesThePath() {
    let file = makeBase().appending(path: "gone.md")
    let client = AttachmentClient.live(base: makeBase())

    let error = #expect(throws: AttachmentError.self) { try client.open(file) }

    #expect(error?.localizedDescription.contains(file.path) == true)
  }
}
