import CustomDump
import SlipstreamCore
import Testing

struct SSEParserTests {
  @Test func daemonShapedFrame() {
    var parser = SSEParser()
    let items = parser.consume(Array("id: 7\nevent: slipstream\ndata: {\"a\":1}\n\n".utf8))
    expectNoDifference(items, [.event(SSEEvent(id: "7", event: "slipstream", data: "{\"a\":1}"))])
  }

  @Test func heartbeatComment() {
    var parser = SSEParser()
    let items = parser.consume(Array(": heartbeat\n\n".utf8))
    expectNoDifference(items, [.comment("heartbeat")])
  }

  @Test func multiLineData() {
    var parser = SSEParser()
    let items = parser.consume(Array("data: line1\ndata: line2\n\n".utf8))
    expectNoDifference(items, [.event(SSEEvent(id: nil, event: nil, data: "line1\nline2"))])
  }

  @Test func crlfFraming() {
    var parser = SSEParser()
    let items = parser.consume(Array("data: hello\r\n\r\n".utf8))
    expectNoDifference(items, [.event(SSEEvent(id: nil, event: nil, data: "hello"))])
  }

  @Test func loneCRFraming() {
    var parser = SSEParser()
    let items = parser.consume(Array("data: hello\r\r".utf8))
    expectNoDifference(items, [.event(SSEEvent(id: nil, event: nil, data: "hello"))])
  }

  @Test func crlfSplitAcrossChunks() {
    var parser = SSEParser()
    let first = parser.consume(Array("data: hello\r".utf8))
    #expect(first.isEmpty)
    let second = parser.consume(Array("\n\r\n".utf8))
    expectNoDifference(second, [.event(SSEEvent(id: nil, event: nil, data: "hello"))])
  }

  @Test func byteAtATimeMultiFrameWithUnicode() {
    var parser = SSEParser()
    let stream = "id: 1\nevent: a\ndata: caf\u{00E9}\n\n: heartbeat\ndata: arrow \u{2192}\n\n"
    var items: [SSEItem] = []
    for byte in Array(stream.utf8) {
      items.append(contentsOf: parser.consume([byte]))
    }
    expectNoDifference(
      items,
      [
        .event(SSEEvent(id: "1", event: "a", data: "café")),
        .comment("heartbeat"),
        .event(SSEEvent(id: nil, event: nil, data: "arrow →")),
      ])
  }

  @Test func bomAtStreamStart() {
    var parser = SSEParser()
    let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    let items = parser.consume(bom + Array("data: hi\n\n".utf8))
    expectNoDifference(items, [.event(SSEEvent(id: nil, event: nil, data: "hi"))])
  }

  @Test func fieldWithoutSpaceAfterColon() {
    var parser = SSEParser()
    let items = parser.consume(Array("data:no-space\n\n".utf8))
    expectNoDifference(items, [.event(SSEEvent(id: nil, event: nil, data: "no-space"))])
  }

  @Test func blockWithoutDataDispatchesNothing() {
    var parser = SSEParser()
    let items = parser.consume(Array("event: only\nid: 5\n\n".utf8))
    #expect(items.isEmpty)
  }

  @Test func idContainingNulIsIgnored() {
    var parser = SSEParser()
    let items = parser.consume(Array("id: 7\nid: 8\u{0000}\ndata: x\n\n".utf8))
    expectNoDifference(items, [.event(SSEEvent(id: "7", event: nil, data: "x"))])
  }

  @Test func unterminatedTrailingBlockNotEmitted() {
    var parser = SSEParser()
    let items = parser.consume(Array("data: incomplete".utf8))
    #expect(items.isEmpty)
  }
}
