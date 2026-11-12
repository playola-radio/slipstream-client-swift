import Dependencies
import Foundation
import SlipstreamCore
import Synchronization
import os

struct AppLogClient: Sendable {
  var write: @Sendable (AppLogLevel, _ category: String, _ message: String) -> Void
  /// Blocks until every queued line is on disk; called on quit.
  var drain: @Sendable () -> Void

  func info(_ category: String, _ message: String) { write(.info, category, message) }
  func error(_ category: String, _ message: String) { write(.error, category, message) }
}

extension AppLogClient: DependencyKey {
  static var liveValue: Self {
    Self(
      write: { AppLogFile.shared.write($0, category: $1, message: $2) },
      drain: { AppLogFile.shared.drain() }
    )
  }

  static var testValue: Self { Self(write: { _, _, _ in }, drain: {}) }

  static var previewValue: Self { testValue }
}

extension DependencyValues {
  var appLog: AppLogClient {
    get { self[AppLogClient.self] }
    set { self[AppLogClient.self] = newValue }
  }
}

final class AppLogFile: Sendable {
  static let shared = AppLogFile(
    url: FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Logs/slipstream/\(fileName)")
  )

  #if DEBUG
    private static let fileName = "app-debug.log"
  #else
    private static let fileName = "app.log"
  #endif

  private let url: URL
  private let maxBytes: Int
  private let queue = DispatchQueue(label: "com.playola.SlipstreamViewer.AppLog")
  private let handle = Mutex<FileHandle?>(nil)
  private let logger = Logger(subsystem: "com.playola.SlipstreamViewer", category: "AppLog")

  init(url: URL, maxBytes: Int = 10 * 1024 * 1024) {
    self.url = url
    self.maxBytes = maxBytes
  }

  func write(_ level: AppLogLevel, category: String, message: String) {
    let line = AppLogLine.format(date: Date(), level: level, category: category, message: message)
    queue.async { [self] in append(line) }
  }

  func drain() {
    queue.sync {}
  }

  private func append(_ line: String) {
    handle.withLock { handle in
      do {
        let file = try handle ?? open()
        handle = file
        let data = Data(line.utf8)
        let end = try file.seekToEnd()
        try file.write(contentsOf: data)
        if Int(end) + data.count > maxBytes {
          handle = nil
          try rotate(file)
        }
      } catch {
        logger.fault("Writing \(self.url.path, privacy: .public) failed: \(error, privacy: .public)")
        try? handle?.close()
        handle = nil
      }
    }
  }

  private func open() throws -> FileHandle {
    let manager = FileManager.default
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !manager.fileExists(atPath: url.path) {
      manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    return try FileHandle(forWritingTo: url)
  }

  private func rotate(_ file: FileHandle) throws {
    try file.close()
    let rotated = url.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: rotated)
    try FileManager.default.moveItem(at: url, to: rotated)
  }
}
