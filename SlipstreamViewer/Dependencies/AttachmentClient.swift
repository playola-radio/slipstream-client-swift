import AppKit
import Dependencies

enum AttachmentError: Error, Equatable, LocalizedError {
  case folder(String)
  case missing(String)
  case notOpened(String)

  var errorDescription: String? {
    switch self {
    case .folder(let path): "\(path) is a folder; only files can be attached"
    case .missing(let path): "The file no longer exists at \(path)"
    case .notOpened(let path): "macOS couldn't open \(path)"
    }
  }
}

/// Writes or copies the files a chat message points at, and opens them from a token.
struct AttachmentClient: Sendable {
  var write: @Sendable (_ name: String, _ data: Data) throws -> URL
  var copy: @Sendable (_ file: URL) async throws -> URL
  var open: @Sendable (_ file: URL) throws -> Void
}

extension AttachmentClient {
  static func live(base: URL) -> Self {
    Self(
      write: { name, data in
        let folder = base.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: file, options: .atomic)
        return file
      },
      copy: { file in try await copyFile(file, into: base) },
      open: { file in
        guard FileManager.default.fileExists(atPath: file.path) else { throw AttachmentError.missing(file.path) }
        guard NSWorkspace.shared.open(file) else { throw AttachmentError.notOpened(file.path) }
      }
    )
  }

  private nonisolated static func copyFile(_ file: URL, into base: URL) async throws -> URL {
    if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
      throw AttachmentError.folder(file.path)
    }
    let name = String(file.lastPathComponent.map { "⟦⟧\n".contains($0) ? "_" : $0 })
    let folder = base.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let copy = folder.appending(path: name, directoryHint: .notDirectory)
      try FileManager.default.copyItem(at: file, to: copy)
      return copy
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }
}

extension AttachmentClient: DependencyKey {
  static var liveValue: Self {
    live(base: URL.applicationSupportDirectory.appending(path: "Slipstream/attachments", directoryHint: .isDirectory))
  }

  static var testValue: Self {
    Self(
      write: unimplemented("AttachmentClient.write", placeholder: URL(fileURLWithPath: "/")),
      copy: unimplemented("AttachmentClient.copy", placeholder: URL(fileURLWithPath: "/")),
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
