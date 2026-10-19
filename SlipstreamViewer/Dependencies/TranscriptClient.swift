import Dependencies
import Foundation
import SlipstreamCore

enum TranscriptLookup: Equatable, Sendable {
  case notFound
  case found([AgentLine])
}

struct TranscriptClient: Sendable {
  var load: @Sendable (_ configDirectory: URL, _ sessionID: UUID) async throws -> TranscriptLookup
}

extension TranscriptClient {
  /// Claude saves a session as `projects/<encoded folder>/<session id>.jsonl`. Scanning every
  /// project folder avoids depending on how the folder name is encoded.
  private static func transcriptFile(in configDirectory: URL, sessionID: UUID) throws -> URL? {
    let projects = configDirectory.appending(path: "projects")
    guard try exists(projects) else { return nil }
    let fileName = "\(sessionID.uuidString.lowercased()).jsonl"
    return try FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
      .map { $0.appending(path: fileName) }
      .first(where: exists)
  }

  /// Unlike `FileManager.fileExists`, a folder that can't be searched throws instead of
  /// looking empty.
  private static func exists(_ file: URL) throws -> Bool {
    var info = stat()
    if stat(file.path, &info) == 0 { return true }
    let code = errno
    if code == ENOENT || code == ENOTDIR { return false }
    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
  }

  private static func decode(_ data: Data) -> [AgentLine] {
    var framer = JSONLineFramer()
    return framer.append(data).map { framed in
      switch framed {
      case .line(let line): AgentLine.decode(line)
      case .overflow: .gap
      }
    }
  }
}

extension TranscriptClient: DependencyKey {
  static var liveValue: Self {
    Self(load: { configDirectory, sessionID in
      guard let file = try transcriptFile(in: configDirectory, sessionID: sessionID) else { return .notFound }
      return .found(decode(try Data(contentsOf: file)))
    })
  }

  static var testValue: Self {
    Self(load: unimplemented("TranscriptClient.load"))
  }
}

extension DependencyValues {
  var transcripts: TranscriptClient {
    get { self[TranscriptClient.self] }
    set { self[TranscriptClient.self] = newValue }
  }
}
