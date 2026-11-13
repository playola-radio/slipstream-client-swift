import Darwin
import Dependencies
import Foundation
import SlipstreamCore
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
    static let fileName = "app-debug.log"
  #else
    static let fileName = "app.log"
  #endif

  let url: URL
  private let maxBytes: UInt64
  private let queue = DispatchQueue(label: "com.playola.SlipstreamViewer.AppLog")
  private let logger = Logger(subsystem: "com.playola.SlipstreamViewer", category: "AppLog")

  init(url: URL, maxBytes: UInt64 = 10 * 1024 * 1024) {
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
    do {
      try withRotationLock {
        let file = try open()
        defer { try? file.close() }
        try file.write(contentsOf: Data(line.utf8))
        if try file.offset() > maxBytes {
          try file.close()
          try rotate()
        }
      }
    } catch {
      logger.fault("Writing \(self.url.path, privacy: .public) failed: \(error, privacy: .public)")
    }
  }

  private func open() throws -> FileHandle {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // O_APPEND, so lines from another running copy of the app land after ours instead of over them.
    let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  private func rotate() throws {
    let rotated = url.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: rotated)
    try FileManager.default.moveItem(at: url, to: rotated)
  }

  private func withRotationLock(_ operation: () throws -> Void) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lockURL = url.appendingPathExtension("lock")
    let descriptor = Darwin.open(lockURL.path, O_WRONLY | O_CREAT, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { flock(descriptor, LOCK_UN) }
    try operation()
  }
}
