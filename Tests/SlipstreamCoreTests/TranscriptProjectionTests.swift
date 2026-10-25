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
    projection.apply(toolUse("Mystery", .object(["file_path": .string("/a/b/Other.swift")]), id: "m"))
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
    projection.apply(
      .user(
        uuid: "u-1", timestamp: nil, isPrompt: false,
        blocks: [.toolResult(toolUseID: "toolu_1", text: "exit 1", isError: true)]))
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

  @Test func removingFailedPromptAfterExitKeepsFutureTurnsSafe() {
    var projection = TranscriptProjection()
    projection.userSent("prompt", id: "prompt")
    projection.endTurn(.failed, duration: .seconds(1), at: t0, id: "first-footer")
    projection.removeUserMessage(id: "prompt")

    projection.endTurn(.stopped, duration: .seconds(1), at: t0, id: "second-footer")

    expectNoDifference(
      projection.items,
      [
        TranscriptItem(id: "first-footer", kind: .turnFooter(ending: .failed, duration: .seconds(1), time: t0)),
        TranscriptItem(id: "second-footer", kind: .turnFooter(ending: .stopped, duration: .seconds(1), time: t0)),
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

  @Test func replyTextReadsPastARelayInTheTurn() {
    var projection = TranscriptProjection()
    projection.userSent("hi", id: "u1")
    projection.apply(.assistant(uuid: "a1", timestamp: nil, blocks: [.text("one")]))
    projection.userSent("Rename it", id: "r1", relay: RelayMark(label: "From Ask", delivery: .pickedUp))
    projection.apply(.assistant(uuid: "a2", timestamp: nil, blocks: [.text("two")]))
    projection.endTurn(.completed, duration: .seconds(1), at: t0, id: "f1")
    expectNoDifference(projection.replyText(endingAt: "f1"), "one\n\ntwo")
  }

  @Test func replyTextStopsAtAnUntimedHistoryTurnsPrompt() {
    let projection = TranscriptProjection.history([
      .user(uuid: "u1", timestamp: nil, isPrompt: true, blocks: [.text("first")]),
      .assistant(uuid: "a1", timestamp: nil, blocks: [.text("earlier reply")]),
      .user(uuid: "u2", timestamp: t0, isPrompt: true, blocks: [.text("second")]),
      .assistant(uuid: "a2", timestamp: t0.addingTimeInterval(1), blocks: [.text("later reply")]),
    ])
    expectNoDifference(projection.replyText(endingAt: "a2#footer"), "later reply")
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

  @Test func historyStopsToolsWhenThePromptWasLost() {
    let projection = TranscriptProjection.history([
      .gap,
      toolUse("Bash", .object(["command": .string("sleep 100")])),
    ])
    expectNoDifference(
      kinds(projection),
      [.gap, .toolCall(name: "Bash", target: "sleep 100", status: .stopped, detail: nil)]
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

  @Test func echoesAreNeverDrawn() {
    var live = TranscriptProjection()
    live.userSent("hi", id: "local-1")
    live.apply(.echo(uuid: "e-1"))
    let reloaded = TranscriptProjection.history([
      .user(uuid: "u1", timestamp: t0, isPrompt: true, blocks: [.text("hi")]),
      .echo(uuid: "u1"),
    ])
    expectNoDifference(kinds(live), [.userMessage("hi")])
    expectNoDifference(
      kinds(reloaded),
      [.userMessage("hi"), .turnFooter(ending: .completed, duration: .zero, time: t0)]
    )
  }

  @Test func relayMarkShownAndUpdated() {
    var projection = TranscriptProjection()
    let waiting = RelayMark(label: "From Ask · greet.py:3-5", delivery: .waiting)
    projection.userSent("Rename it", id: "relay-1", relay: waiting)
    expectNoDifference(projection.items, [TranscriptItem(id: "relay-1", kind: .userMessage("Rename it", relay: waiting))])

    projection.markRelay(id: "relay-1", delivery: .pickedUp)

    expectNoDifference(
      projection.items,
      [
        TranscriptItem(
          id: "relay-1",
          kind: .userMessage("Rename it", relay: RelayMark(label: "From Ask · greet.py:3-5", delivery: .pickedUp)))
      ]
    )
  }

  @Test func markRelayLeavesOtherMessagesAlone() {
    var projection = TranscriptProjection()
    projection.userSent("plain", id: "local-1")
    projection.markRelay(id: "local-1", delivery: .notDelivered)
    projection.markRelay(id: "missing", delivery: .notDelivered)
    expectNoDifference(projection.items, [TranscriptItem(id: "local-1", kind: .userMessage("plain"))])
  }

  @Test func reloadedRelayShowsUnmarked() {
    let projection = TranscriptProjection.history([
      .user(uuid: "c9d8e7f6-a5b4-4c3d-8e2f-1a0b9c8d7e6f", timestamp: t0, isPrompt: true, blocks: [.text("Rename it")]),
      .assistant(uuid: "a1", timestamp: t0.addingTimeInterval(2), blocks: [.text("Done.")]),
    ])
    expectNoDifference(
      kinds(projection),
      [
        .userMessage("Rename it"),
        .reply("Done."),
        .turnFooter(ending: .completed, duration: .seconds(2), time: t0.addingTimeInterval(2)),
      ]
    )
  }

  @Test func reloadDrawsMidTurnRelayInsideItsTurn() {
    let projection = TranscriptProjection.history([
      .user(uuid: "u1", timestamp: t0, isPrompt: true, blocks: [.text("go")]),
      .assistant(
        uuid: "a1", timestamp: t0.addingTimeInterval(1),
        blocks: [.toolUse(id: "toolu_1", name: "Bash", input: .object(["command": .string("sleep 15")]))]),
      .queuedMessage(uuid: "q1", text: "Also add a test."),
      .user(
        uuid: "u2", timestamp: t0.addingTimeInterval(16), isPrompt: false,
        blocks: [.toolResult(toolUseID: "toolu_1", text: "", isError: false)]),
      .assistant(uuid: "a2", timestamp: t0.addingTimeInterval(18), blocks: [.text("Done, with a test.")]),
    ])
    expectNoDifference(
      projection.items,
      [
        TranscriptItem(id: "u1#0", kind: .userMessage("go")),
        TranscriptItem(id: "toolu_1", kind: .toolCall(name: "Bash", target: "sleep 15", status: .done, detail: "")),
        TranscriptItem(id: "q1#0", kind: .userMessage("Also add a test.")),
        TranscriptItem(id: "a2#0", kind: .reply("Done, with a test.")),
        TranscriptItem(
          id: "a2#footer",
          kind: .turnFooter(ending: .completed, duration: .seconds(18), time: t0.addingTimeInterval(18))),
      ]
    )
  }

  @Test func liveQueuedCommandNotDrawn() {
    var projection = TranscriptProjection()
    projection.userSent("Also add a test.", id: "relay-1")
    projection.apply(.queuedMessage(uuid: "q1", text: "Also add a test."))
    expectNoDifference(kinds(projection), [.userMessage("Also add a test.")])
  }

  @Test func waitingRelaysStayAtTheBottom() {
    var projection = TranscriptProjection()
    let waiting = RelayMark(label: "From Ask · greet.py:3-5", delivery: .waiting)
    projection.userSent("go", id: "local-1")
    projection.userSent("Rename it", id: "relay-1", relay: waiting)

    projection.apply(.assistant(uuid: "a1", timestamp: nil, blocks: [.text("Working.")]))
    projection.endTurn(.completed, duration: .seconds(3), at: t0, id: "turn-1")
    projection.markRelay(id: "relay-1", delivery: .pickedUp)
    projection.apply(.assistant(uuid: "a2", timestamp: nil, blocks: [.text("Renamed.")]))

    expectNoDifference(
      kinds(projection),
      [
        .userMessage("go"),
        .reply("Working."),
        .turnFooter(ending: .completed, duration: .seconds(3), time: t0),
        .userMessage("Rename it", relay: RelayMark(label: "From Ask · greet.py:3-5", delivery: .pickedUp)),
        .reply("Renamed."),
      ])
  }

  @Test func toolsAboveAWaitingRelayStopWhenTheTurnEnds() {
    var projection = TranscriptProjection()
    projection.userSent("go", id: "local-1")
    projection.apply(
      .assistant(
        uuid: "a1", timestamp: nil,
        blocks: [.toolUse(id: "toolu_1", name: "Bash", input: .object(["command": .string("sleep 15")]))]))
    projection.userSent("Rename it", id: "relay-1", relay: RelayMark(label: "From Ask", delivery: .waiting))

    projection.endTurn(.stopped, duration: .seconds(3), at: t0, id: "turn-1")

    expectNoDifference(
      kinds(projection),
      [
        .userMessage("go"),
        .toolCall(name: "Bash", target: "sleep 15", status: .stopped, detail: nil),
        .turnFooter(ending: .stopped, duration: .seconds(3), time: t0),
        .userMessage("Rename it", relay: RelayMark(label: "From Ask", delivery: .waiting)),
      ])
  }

  @Test func undeliveredRelayStaysBelowTheFooter() {
    var projection = TranscriptProjection()
    projection.userSent("go", id: "local-1")
    projection.userSent("Rename it", id: "relay-1", relay: RelayMark(label: "From Ask", delivery: .waiting))

    projection.markRelay(id: "relay-1", delivery: .notDelivered)
    projection.endTurn(.stopped, duration: .seconds(3), at: t0, id: "turn-1")

    expectNoDifference(
      kinds(projection),
      [
        .userMessage("go"),
        .turnFooter(ending: .stopped, duration: .seconds(3), time: t0),
        .userMessage("Rename it", relay: RelayMark(label: "From Ask", delivery: .notDelivered)),
      ])
  }
}
