import CustomDump
import Foundation
import SlipstreamCore
import Testing

struct HistoryCompactionTests {
  private let compaction = HistoryCompaction(
    triggerLines: 5, triggerBytes: 50, keepLines: 4, keepBytes: 30)

  @Test func belowTriggerNeedsNothing() {
    #expect(!compaction.needsCompaction(lines: 4, bytes: 49))
  }

  @Test func lineTriggerFires() {
    #expect(compaction.needsCompaction(lines: 5, bytes: 10))
  }

  @Test func byteTriggerFires() {
    #expect(compaction.needsCompaction(lines: 1, bytes: 50))
  }

  @Test func keepsLastLines() {
    let log = Array("a\nb\nc\nd\ne\nf\n".utf8)
    expectNoDifference(compaction.compacted(log), Array("c\nd\ne\nf\n".utf8))
  }

  @Test func keepsByteBudgetAtLineBoundary() {
    let log = Array("line-0001\nline-0002\nline-0003\nline-0004\n".utf8)
    expectNoDifference(compaction.compacted(log), Array("line-0002\nline-0003\nline-0004\n".utf8))
  }

  @Test func oversizedLineKeepsItsEnd() {
    let log = Array("0123456789".utf8) + Array(repeating: UInt8(ascii: "x"), count: 90)
    expectNoDifference(compaction.compacted(log), Array(log.suffix(30)))
  }
}
