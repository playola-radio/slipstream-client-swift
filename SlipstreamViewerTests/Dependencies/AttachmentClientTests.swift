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

    let file = try client.write("PR instructions.md", Data("Do the thing".utf8))

    expectNoDifference(file.lastPathComponent, "PR instructions.md")
    #expect(UUID(uuidString: file.deletingLastPathComponent().lastPathComponent) != nil)
    expectNoDifference(file.deletingLastPathComponent().deletingLastPathComponent().path, base.path)
    expectNoDifference(try String(contentsOf: file, encoding: .utf8), "Do the thing")
  }

  @Test func copyKeepsTheNameUnderAFreshFolder() async throws {
    let base = makeBase()
    let source = makeBase().appending(path: "my note (1).txt")
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: source)
    let client = AttachmentClient.live(base: base)

    let copy = try await client.copy(source)

    expectNoDifference(copy.lastPathComponent, "my note (1).txt")
    #expect(UUID(uuidString: copy.deletingLastPathComponent().lastPathComponent) != nil)
    expectNoDifference(copy.deletingLastPathComponent().deletingLastPathComponent().path, base.path)
    expectNoDifference(try Data(contentsOf: copy), Data("hello".utf8))
  }

  @Test func copyReplacesMarkerBreakingCharacters() async throws {
    let base = makeBase()
    let source = makeBase().appending(path: "a⟦b⟧\nc.txt")
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: source)
    let client = AttachmentClient.live(base: base)

    let copy = try await client.copy(source)

    expectNoDifference(copy.lastPathComponent, "a_b__c.txt")
  }

  @Test func copyRefusesAFolder() async throws {
    let base = makeBase()
    let source = makeBase()
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: source)
    }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let client = AttachmentClient.live(base: base)

    await #expect(throws: AttachmentError.folder(source.path)) { try await client.copy(source) }

    expectNoDifference(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
  }

  @Test func copyOfMissingFileCleansUp() async throws {
    let base = makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let client = AttachmentClient.live(base: base)

    await #expect(throws: (any Error).self) { try await client.copy(makeBase().appending(path: "gone.txt")) }

    expectNoDifference(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
  }

  @Test func copyOfUnreadableFileCleansUp() async throws {
    let base = makeBase()
    let source = makeBase().appending(path: "secret.txt")
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
    let client = AttachmentClient.live(base: base)

    await #expect(throws: (any Error).self) { try await client.copy(source) }

    expectNoDifference(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
  }

  @Test func copyFollowsASymlinkToTheFile() async throws {
    let base = makeBase()
    let folder = makeBase()
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: folder)
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: folder.appending(path: "original.txt"))
    let link = folder.appending(path: "link.txt")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "original.txt")
    let client = AttachmentClient.live(base: base)

    let copy = try await client.copy(link)

    expectNoDifference(copy.lastPathComponent, "link.txt")
    expectNoDifference(try copy.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
    expectNoDifference(try Data(contentsOf: copy), Data("hello".utf8))
  }

  @Test func openOfMissingFileNamesThePath() {
    let file = makeBase().appending(path: "gone.md")
    let client = AttachmentClient.live(base: makeBase())

    let error = #expect(throws: AttachmentError.self) { try client.open(file) }

    #expect(error?.localizedDescription.contains(file.path) == true)
  }
}
