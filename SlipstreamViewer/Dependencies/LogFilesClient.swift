import Dependencies
import Foundation

enum LogFile: CaseIterable, Sendable {
  case app, daemon

  var name: String {
    switch self {
    case .app: AppLogFile.fileName
    case .daemon: RecorderServiceClient.logFile.lastPathComponent
    }
  }
}

struct LogFilesClient: Sendable {
  /// The end of the log, at most `LogFilesClient.tailBytes` long, starting on a whole line.
  var tail: @Sendable (LogFile) throws -> String
}

extension LogFilesClient {
  static let tailBytes: UInt64 = 64 * 1024
}

extension LogFilesClient: DependencyKey {
  static var liveValue: Self {
    Self(tail: { file in
      let url =
        switch file {
        case .app: AppLogFile.shared.url
        case .daemon: RecorderServiceClient.logFile
        }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let end = try handle.seekToEnd()
      guard end > tailBytes else {
        try handle.seek(toOffset: 0)
        return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
      }
      try handle.seek(toOffset: end - tailBytes)
      let data = try handle.readToEnd() ?? Data()
      let wholeLines = data.firstIndex(of: UInt8(ascii: "\n")).map { data[($0 + 1)...] } ?? data
      return String(decoding: wholeLines, as: UTF8.self)
    })
  }

  static var testValue: Self {
    Self(tail: unimplemented("LogFilesClient.tail", placeholder: ""))
  }
}

extension DependencyValues {
  var logFiles: LogFilesClient {
    get { self[LogFilesClient.self] }
    set { self[LogFilesClient.self] = newValue }
  }
}
