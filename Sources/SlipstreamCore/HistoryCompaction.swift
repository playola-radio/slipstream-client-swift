import Foundation

public struct HistoryCompaction: Sendable, Equatable {
  public static let terminal = HistoryCompaction(
    triggerLines: 5_000, triggerBytes: 4_194_304, keepLines: 4_000, keepBytes: 3_145_728)

  private static let lf: UInt8 = 0x0A

  private let triggerLines: Int
  private let triggerBytes: Int
  private let keepLines: Int
  private let keepBytes: Int

  public init(triggerLines: Int, triggerBytes: Int, keepLines: Int, keepBytes: Int) {
    self.triggerLines = triggerLines
    self.triggerBytes = triggerBytes
    self.keepLines = keepLines
    self.keepBytes = keepBytes
  }

  public func needsCompaction(lines: Int, bytes: Int) -> Bool {
    lines >= triggerLines || bytes >= triggerBytes
  }

  public func compacted(_ log: [UInt8]) -> [UInt8] {
    let end = log.count
    var start = end
    var lineEnd = end
    var taken = 0
    while taken < keepLines && lineEnd > 0 {
      var lineStart = lineEnd - 1
      while lineStart > 0 && log[lineStart - 1] != Self.lf && end - lineStart <= keepBytes {
        lineStart -= 1
      }
      if end - lineStart > keepBytes { break }
      start = lineStart
      lineEnd = lineStart
      taken += 1
    }
    if taken == 0 && keepLines > 0 {
      return Array(log.suffix(keepBytes))
    }
    return Array(log[start...])
  }

  public static func lineCount(_ bytes: some Collection<UInt8>) -> Int {
    bytes.reduce(0) { $0 + ($1 == lf ? 1 : 0) }
  }
}
