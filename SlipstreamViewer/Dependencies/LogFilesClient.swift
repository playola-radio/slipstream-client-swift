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
    live { file in
      switch file {
      case .app: AppLogFile.shared.url
      case .daemon: RecorderServiceClient.logFile
      }
    }
  }

  /// Fills from the rotated `<name>.1` when the log is shorter than the budget, so a log that just
  /// rotated still shows what led up to it.
  static func live(url: @escaping @Sendable (LogFile) -> URL, tailBytes: UInt64 = tailBytes) -> Self {
    Self(tail: { file in
      let url = url(file)
      var data = Data()
      var truncated = false
      var failure: (any Error)?
      do {
        (data, truncated) = try lastBytes(of: url, upTo: tailBytes)
      } catch {
        failure = error
      }
      if data.count < tailBytes,
        let older = try? lastBytes(of: url.appendingPathExtension("1"), upTo: tailBytes - UInt64(data.count))
      {
        data = older.data + data
        truncated = older.truncated
        failure = nil
      }
      if let failure { throw failure }
      return String(decoding: truncated ? wholeLines(data) : data, as: UTF8.self)
    })
  }

  private static func lastBytes(of url: URL, upTo budget: UInt64) throws -> (data: Data, truncated: Bool) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    let start = end > budget ? end - budget : 0
    try handle.seek(toOffset: start)
    return (try handle.read(upToCount: Int(end - start)) ?? Data(), start > 0)
  }

  /// Drops the partial first line, unless the whole budget is one line.
  private static func wholeLines(_ data: Data) -> Data {
    guard let newline = data.firstIndex(of: UInt8(ascii: "\n")), newline < data.index(before: data.endIndex)
    else { return data }
    return data[data.index(after: newline)...]
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
