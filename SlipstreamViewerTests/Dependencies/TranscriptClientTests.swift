import CustomDump
import Foundation
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

struct TranscriptClientTests {
  let sessionID = UUID(uuidString: "B4D8A619-0000-4000-8000-000000000001")!

  @Test func findsFileInAnyProjectFolder() async throws {
    let configDirectory = try makeConfigDirectory()
    defer { try? FileManager.default.removeItem(at: configDirectory) }
    try makeProject("-tmp-a", in: configDirectory)
    let overLong = "{\"type\":\"user\",\"text\":\"\(String(repeating: "x", count: 1_048_576))\"}"
    try write(
      "{\"type\":\"ai-title\",\"aiTitle\":\"Fix the bug\"}\n\(overLong)\n{\"type\":\"ai-title\",\"aiTitle\":\"Bug fix\"}\n",
      to: makeProject("-tmp-b", in: configDirectory)
        .appending(path: "\(sessionID.uuidString.lowercased()).jsonl")
    )

    let lookup = try await TranscriptClient.liveValue.load(configDirectory, sessionID)

    expectNoDifference(lookup, .found([.title("Fix the bug"), .gap, .title("Bug fix")]))
  }

  @Test func notFoundWhenAbsent() async throws {
    let configDirectory = try makeConfigDirectory()
    defer { try? FileManager.default.removeItem(at: configDirectory) }
    try write("{}\n", to: makeProject("-tmp-a", in: configDirectory).appending(path: "\(UUID()).jsonl"))

    let lookup = try await TranscriptClient.liveValue.load(configDirectory, sessionID)

    expectNoDifference(lookup, .notFound)
  }

  @Test func notFoundWithoutProjectsFolder() async throws {
    let configDirectory = try makeConfigDirectory()
    defer { try? FileManager.default.removeItem(at: configDirectory) }

    let lookup = try await TranscriptClient.liveValue.load(configDirectory, sessionID)

    expectNoDifference(lookup, .notFound)
  }

  @Test func unreadableThrows() async throws {
    let configDirectory = try makeConfigDirectory()
    defer { try? FileManager.default.removeItem(at: configDirectory) }
    let file = try makeProject("-tmp-a", in: configDirectory)
      .appending(path: "\(sessionID.uuidString.lowercased()).jsonl")
    try write("{}\n", to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

    await #expect(throws: (any Error).self) {
      try await TranscriptClient.liveValue.load(configDirectory, sessionID)
    }
  }

  @Test func unsearchableProjectFolderThrows() async throws {
    let configDirectory = try makeConfigDirectory()
    let project = try makeProject("-tmp-a", in: configDirectory)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: project.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path)
      try? FileManager.default.removeItem(at: configDirectory)
    }

    await #expect(throws: (any Error).self) {
      try await TranscriptClient.liveValue.load(configDirectory, sessionID)
    }
  }
}

private func makeConfigDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appending(path: "transcripts-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

@discardableResult
private func makeProject(_ name: String, in configDirectory: URL) throws -> URL {
  let project = configDirectory.appending(path: "projects/\(name)")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  return project
}

private func write(_ text: String, to file: URL) throws {
  try Data(text.utf8).write(to: file)
}
