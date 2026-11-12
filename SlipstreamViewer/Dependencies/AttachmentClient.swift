import AppKit
import Dependencies

enum AttachmentError: Error, Equatable, LocalizedError {
  case missing(String)
  case notOpened(String)

  var errorDescription: String? {
    switch self {
    case .missing(let path): "The file no longer exists at \(path)"
    case .notOpened(let path): "macOS couldn't open \(path)"
    }
  }
}

/// Writes the instruction files a chat message points at, and opens them from a chip.
struct AttachmentClient: Sendable {
  var write: @Sendable (_ name: String, _ contents: String) throws -> URL
  var open: @Sendable (_ file: URL) throws -> Void
}

extension AttachmentClient {
  static func live(base: URL) -> Self {
    Self(
      write: { name, contents in
        let folder = base.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name, directoryHint: .notDirectory)
        try Data(contents.utf8).write(to: file, options: .atomic)
        return file
      },
      open: { file in
        guard FileManager.default.fileExists(atPath: file.path) else { throw AttachmentError.missing(file.path) }
        guard NSWorkspace.shared.open(file) else { throw AttachmentError.notOpened(file.path) }
      }
    )
  }
}

extension AttachmentClient: DependencyKey {
  static var liveValue: Self {
    live(base: URL.applicationSupportDirectory.appending(path: "Slipstream/attachments", directoryHint: .isDirectory))
  }

  static var testValue: Self {
    Self(
      write: unimplemented("AttachmentClient.write", placeholder: URL(fileURLWithPath: "/")),
      open: unimplemented("AttachmentClient.open")
    )
  }
}

extension DependencyValues {
  var attachments: AttachmentClient {
    get { self[AttachmentClient.self] }
    set { self[AttachmentClient.self] = newValue }
  }
}
