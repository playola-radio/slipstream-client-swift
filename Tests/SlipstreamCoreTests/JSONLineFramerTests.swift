import CustomDump
import Foundation
import SlipstreamCore
import Testing

struct JSONLineFramerTests {
  @Test func splitsLinesAcrossChunks() {
    var framer = JSONLineFramer()
    expectNoDifference(framer.append(Data(#"{"a":"#.utf8)), [])
    expectNoDifference(
      framer.append(Data("1}\n{\"b\":2}\n".utf8)),
      [.line(Data(#"{"a":1}"#.utf8)), .line(Data(#"{"b":2}"#.utf8))]
    )
  }

  @Test func dropsCarriageReturn() {
    var framer = JSONLineFramer()
    expectNoDifference(framer.append(Data("x\r\n".utf8)), [.line(Data("x".utf8))])
  }

  @Test func overLongLineBecomesOverflowAndNextLineParses() {
    var framer = JSONLineFramer(maxLineBytes: 8)
    var framed = framer.append(Data("0123456789".utf8))
    framed += framer.append(Data("AB\n{}\n".utf8))
    expectNoDifference(framed, [.overflow, .line(Data("{}".utf8))])
  }

  @Test func emptyLinesAreSkipped() {
    var framer = JSONLineFramer()
    expectNoDifference(framer.append(Data("\n\r\nx\n\n".utf8)), [.line(Data("x".utf8))])
  }
}
