import Dependencies
import Foundation
import IssueReporting
import SlipstreamCore

struct TerminalHistoryClient: Sendable {
  var read: @Sendable (_ tab: UUID) async -> [UInt8]
  var append: @Sendable (_ tab: UUID, _ bytes: [UInt8]) -> Void
  var flush: @Sendable (_ tab: UUID) async -> Void
  var delete: @Sendable (_ tab: UUID) async -> Void
}

extension TerminalHistoryClient {
  static func live(directory: URL, compaction: HistoryCompaction = .terminal) -> Self {
    let writer = TerminalHistoryWriter(directory: directory, compaction: compaction)
    return Self(
      read: { tab in await writer.read(tab) },
      append: { tab, bytes in writer.append(tab, bytes) },
      flush: { tab in await writer.flush(tab) },
      delete: { tab in await writer.delete(tab) }
    )
  }
}

/// Every method runs on one serial queue, so the state below is only touched there and
/// `append` order is call order.
private final class TerminalHistoryWriter: @unchecked Sendable {
  private final class Log {
    var handle: FileHandle
    var lines: Int
    var bytes: Int

    init(handle: FileHandle, lines: Int, bytes: Int) {
      self.handle = handle
      self.lines = lines
      self.bytes = bytes
    }
  }

  private let directory: URL
  private let compaction: HistoryCompaction
  private let queue = DispatchQueue(label: "TerminalHistoryClient")
  private var logs: [UUID: Log] = [:]
  private var failedTabs: Set<UUID> = []
  private var deletedTabs: Set<UUID> = []

  init(directory: URL, compaction: HistoryCompaction) {
    self.directory = directory
    self.compaction = compaction
  }

  func append(_ tab: UUID, _ bytes: [UInt8]) {
    queue.async { self.write(bytes, to: tab) }
  }

  /// Also closes the tab's file, since a flush comes when its output ends; a later append
  /// reopens it.
  func flush(_ tab: UUID) async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.close(tab)
        continuation.resume()
      }
    }
  }

  func read(_ tab: UUID) async -> [UInt8] {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: self.contents(of: tab)) }
    }
  }

  func delete(_ tab: UUID) async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.remove(tab)
        continuation.resume()
      }
    }
  }

  private func url(for tab: UUID) -> URL {
    directory.appending(component: "\(tab.uuidString).log")
  }

  private func write(_ bytes: [UInt8], to tab: UUID) {
    guard !deletedTabs.contains(tab), !failedTabs.contains(tab) else { return }
    do {
      let log = try logs[tab] ?? open(tab)
      logs[tab] = log
      try log.handle.write(contentsOf: Data(bytes))
      log.lines += HistoryCompaction.lineCount(bytes)
      log.bytes += bytes.count
      if compaction.needsCompaction(lines: log.lines, bytes: log.bytes) {
        try compact(log, for: tab)
      }
    } catch {
      try? logs.removeValue(forKey: tab)?.handle.close()
      failedTabs.insert(tab)
      reportIssue(error)
    }
  }

  private func open(_ tab: UUID) throws -> Log {
    let file = url(for: tab)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: file.path) {
      FileManager.default.createFile(atPath: file.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: file)
    let existing = try Data(contentsOf: file)
    try handle.seekToEnd()
    return Log(
      handle: handle, lines: HistoryCompaction.lineCount(existing), bytes: existing.count)
  }

  private func compact(_ log: Log, for tab: UUID) throws {
    let file = url(for: tab)
    let temporary = file.appendingPathExtension("tmp")
    let kept = compaction.compacted(Array(try Data(contentsOf: file)))
    try Data(kept).write(to: temporary)
    try log.handle.close()
    _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    log.handle = try FileHandle(forWritingTo: file)
    try log.handle.seekToEnd()
    log.lines = HistoryCompaction.lineCount(kept)
    log.bytes = kept.count
  }

  private func close(_ tab: UUID) {
    guard let log = logs.removeValue(forKey: tab) else { return }
    do {
      try log.handle.synchronize()
      try log.handle.close()
    } catch {
      reportIssue(error)
    }
  }

  private func contents(of tab: UUID) -> [UInt8] {
    do {
      return Array(try Data(contentsOf: url(for: tab)))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    } catch {
      reportIssue(error)
      return []
    }
  }

  private func remove(_ tab: UUID) {
    deletedTabs.insert(tab)
    failedTabs.remove(tab)
    try? logs.removeValue(forKey: tab)?.handle.close()
    do {
      try FileManager.default.removeItem(at: url(for: tab))
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
    } catch {
      reportIssue(error)
    }
  }
}

extension TerminalHistoryClient: DependencyKey {
  static var liveValue: Self {
    .live(
      directory: .applicationSupportDirectory
        .appending(component: Bundle.main.bundleIdentifier ?? "com.playola.SlipstreamViewer")
        .appending(component: "terminals"))
  }

  static var testValue: Self {
    Self(
      read: unimplemented("TerminalHistoryClient.read", placeholder: []),
      append: unimplemented("TerminalHistoryClient.append"),
      flush: unimplemented("TerminalHistoryClient.flush"),
      delete: unimplemented("TerminalHistoryClient.delete")
    )
  }
}

extension DependencyValues {
  var terminalHistory: TerminalHistoryClient {
    get { self[TerminalHistoryClient.self] }
    set { self[TerminalHistoryClient.self] = newValue }
  }
}
