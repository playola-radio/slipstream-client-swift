import CustomDump
import Foundation
import SlipstreamCore
import Testing

private func fixtureLines(_ name: String) throws -> [AgentLine] {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/claude"))
  var framer = JSONLineFramer()
  return framer.append(try Data(contentsOf: url)).compactMap {
    if case .line(let data) = $0 { return AgentLine.decode(data) }
    return nil
  }
}

private let t0 = Date(timeIntervalSince1970: 1_792_335_600)

private func toolUse(_ name: String, _ input: JSONValue, id: String = "toolu_1") -> AgentLine {
  .assistant(uuid: "a-\(id)", timestamp: nil, blocks: [.toolUse(id: id, name: name, input: input)])
}

private func toolResult(id: String = "toolu_1", text: String = "ok", isError: Bool = false) -> AgentLine {
  .user(
    uuid: "u-\(id)", timestamp: nil, isPrompt: false,
    blocks: [.toolResult(toolUseID: id, text: text, isError: isError)])
}

private func kinds(_ projection: TranscriptProjection) -> [TranscriptItem.Kind] {
  projection.items.map(\.kind)
}

struct TranscriptProjectionTests {
  @Test func liveTurnBuildsRowsInOrder() throws {
    var projection = TranscriptProjection()
    projection.userSent("Read a.txt", id: "local-1")
    for line in try fixtureLines("live-turn") { projection.apply(line) }
    projection.endTurn(.completed, duration: .seconds(41), at: t0, id: "local-2")
    expectNoDifference(
      projection.items,
      [
        TranscriptItem(id: "local-1", kind: .userMessage("Read a.txt")),
        TranscriptItem(id: "a-1#0", kind: .thinking("Check the file first.")),
        TranscriptItem(
          id: "toolu_01",
          kind: .toolCall(name: "Bash", target: "cat a.txt", status: .done, detail: "hello\nworld")),
        TranscriptItem(id: "a-2#0", kind: .reply("The file says hello.")),
        TranscriptItem(id: "a-3#0", kind: .reply("Anything else?")),
        TranscriptItem(id: "local-2", kind: .turnFooter(ending: .completed, duration: .seconds(41), time: t0)),
      ]
    )
  }

  @Test func toolCallTargetsFromMainInput() {
    var projection = TranscriptProjection()
    projection.apply(toolUse("Edit", .object(["file_path": .string("/a/b/File.swift")]), id: "e"))
    projection.apply(toolUse("Bash", .object(["command": .string("swift test")]), id: "b"))
    projection.apply(toolUse("Mystery", .object(["x": .number(1)]), id: "m"))
    expectNoDifference(
      kinds(projection),
      [
        .toolCall(name: "Edit", target: "File.swift", status: .running, detail: nil),
        .toolCall(name: "Bash", target: "swift test", status: .running, detail: nil),
        .toolCall(name: "Mystery", target: nil, status: .running, detail: nil),
      ]
    )
  }

  @Test func failedToolResultMarksFailed() {
    var projection = TranscriptProjection()
    projection.apply(toolUse("Bash", .object(["command": .string("false")])))
    projection.apply(toolResult(text: "exit 1", isError: true))
    expectNoDifference(
      kinds(projection),
      [.toolCall(name: "Bash", target: "false", status: .failed, detail: "exit 1")]
    )
  }

  @Test func endTurnStopsRunningTools() {
    var projection = TranscriptProjection()
    projection.apply(toolUse("Bash", .object(["command": .string("sleep 100")])))
    projection.endTurn(.stopped, duration: .seconds(3), at: t0, id: "f")
    expectNoDifference(
      kinds(projection),
      [
        .toolCall(name: "Bash", target: "sleep 100", status: .stopped, detail: nil),
        .turnFooter(ending: .stopped, duration: .seconds(3), time: t0),
      ]
    )
  }

  @Test func interruptMarkerIsNotABubble() throws {
    var projection = TranscriptProjection()
    for line in try fixtureLines("live-interrupt") { projection.apply(line) }
    expectNoDifference(projection.items, [])
  }

  @Test func gapAddsGapRow() {
    var projection = TranscriptProjection()
    projection.apply(.gap)
    projection.apply(.gap)
    expectNoDifference(kinds(projection), [.gap, .gap])
    #expect(Set(projection.items.map(\.id)).count == 2)
  }

  @Test func nonRowLinesAddNothing() {
    var projection = TranscriptProjection()
    projection.apply(.result(durationMs: 1, isError: false, text: "x"))
    projection.apply(.controlRequest(requestID: "r", subtype: "can_use_tool", input: nil))
    projection.apply(.title("T"))
    projection.apply(.ignored)
    expectNoDifference(projection.items, [])
  }

  @Test func replyTextCollectsTheTurnsReplies() {
    var projection = TranscriptProjection()
    projection.apply(.assistant(uuid: "a1", timestamp: nil, blocks: [.text("one"), .text("two")]))
    projection.endTurn(.completed, duration: .seconds(1), at: t0, id: "f1")
    projection.apply(.assistant(uuid: "a2", timestamp: nil, blocks: [.thinking("hm"), .text("three")]))
    projection.endTurn(.completed, duration: .seconds(1), at: t0, id: "f2")
    expectNoDifference(projection.replyText(endingAt: "f1"), "one\n\ntwo")
    expectNoDifference(projection.replyText(endingAt: "f2"), "three")
    expectNoDifference(projection.replyText(endingAt: "missing"), "")
  }

  @Test func historyFootersFromTimestamps() throws {
    let projection = TranscriptProjection.history(try fixtureLines("transcript"))
    let footers = projection.items.compactMap { item -> (String, TranscriptItem.Kind)? in
      if case .turnFooter = item.kind { return (item.id, item.kind) }
      return nil
    }
    expectNoDifference(footers.map(\.0), ["t-a2#footer", "t-a3#footer"])
    expectNoDifference(
      footers.map(\.1),
      [
        .turnFooter(ending: .completed, duration: .seconds(5), time: t0.addingTimeInterval(5)),
        .turnFooter(ending: .completed, duration: .seconds(2), time: t0.addingTimeInterval(62)),
      ]
    )
    expectNoDifference(
      kinds(projection).filter { if case .turnFooter = $0 { false } else { true } },
      [
        .userMessage("Fix the bug"),
        .reply("Looking."),
        .toolCall(name: "Read", target: "a.txt", status: .done, detail: "hello"),
        .reply("Fixed."),
        .userMessage("Thanks"),
        .reply("You're welcome."),
      ]
    )
  }

  @Test func historyTurnWithInterruptMarkerEndsStopped() {
    let projection = TranscriptProjection.history([
      .user(uuid: "u1", timestamp: t0, isPrompt: true, blocks: [.text("go")]),
      toolUse("Bash", .object(["command": .string("sleep 100")])),
      .user(
        uuid: "u2", timestamp: t0.addingTimeInterval(4), isPrompt: false,
        blocks: [.text("[Request interrupted by user for tool use]")]),
    ])
    expectNoDifference(
      kinds(projection),
      [
        .userMessage("go"),
        .toolCall(name: "Bash", target: "sleep 100", status: .stopped, detail: nil),
        .turnFooter(ending: .stopped, duration: .seconds(4), time: t0.addingTimeInterval(4)),
      ]
    )
  }

  @Test func idsAreStable() throws {
    let lines = try fixtureLines("live-turn")
    var first = TranscriptProjection()
    var second = TranscriptProjection()
    for line in lines {
      first.apply(line)
      second.apply(line)
    }
    expectNoDifference(first.items.map(\.id), second.items.map(\.id))
    expectNoDifference(first.items.map(\.id), ["a-1#0", "toolu_01", "a-2#0", "a-3#0"])
  }
}
