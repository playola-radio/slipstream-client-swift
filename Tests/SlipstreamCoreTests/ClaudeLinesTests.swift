import CustomDump
import Foundation
import SlipstreamCore
import Testing

private func fixtureLines(_ name: String) throws -> [Data] {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/claude"))
  var framer = JSONLineFramer()
  return framer.append(try Data(contentsOf: url)).compactMap {
    if case .line(let data) = $0 { return data }
    return nil
  }
}

private func decoded(_ name: String) throws -> [AgentLine] {
  try fixtureLines(name).map(AgentLine.decode)
}

private func decode(_ json: String) -> AgentLine {
  AgentLine.decode(Data(json.utf8))
}

struct ClaudeLinesTests {
  @Test func decodesLiveTurn() throws {
    expectNoDifference(
      try decoded("live-turn"),
      [
        .ignored,
        .ignored,
        .assistant(
          uuid: "a-1", timestamp: nil,
          blocks: [
            .thinking("Check the file first."),
            .toolUse(id: "toolu_01", name: "Bash", input: .object(["command": .string("cat a.txt")])),
          ]),
        .user(
          uuid: "u-1", timestamp: nil, isPrompt: false,
          blocks: [.toolResult(toolUseID: "toolu_01", text: "hello\nworld", isError: false)]),
        .assistant(uuid: "a-2", timestamp: nil, blocks: [.text("The file says hello.")]),
        .assistant(uuid: "a-3", timestamp: nil, blocks: [.text("Anything else?")]),
        .result(durationMs: 41000, isError: false, text: "Anything else?"),
        .ignored,
      ]
    )
  }

  @Test func decodesInterruptLines() throws {
    expectNoDifference(
      try decoded("live-interrupt"),
      [
        .ignored,
        .user(
          uuid: "u-9", timestamp: nil, isPrompt: false,
          blocks: [.text("[Request interrupted by user for tool use]")]),
        .result(
          durationMs: 5200, isError: true,
          text: "[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"),
        .ignored,
      ]
    )
  }

  @Test func decodesControlRequest() throws {
    expectNoDifference(
      try decoded("control-can-use-tool"),
      [
        .controlRequest(
          requestID: "req-1", subtype: "can_use_tool",
          input: .object([
            "command": .string("ls"),
            "recursive": .bool(false),
            "depth": .number(2),
            "tags": .array([.string("a"), .null]),
          ]))
      ]
    )
  }

  @Test func replayedUserLineIsAnEcho() {
    expectNoDifference(
      decode(
        #"{"type":"user","uuid":"c9d8e7f6-a5b4-4c3d-8e2f-1a0b9c8d7e6f","isReplay":true,"timestamp":"2026-10-25T15:16:12.607Z","session_id":"s","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#
      ),
      .echo(uuid: "c9d8e7f6-a5b4-4c3d-8e2f-1a0b9c8d7e6f")
    )
  }

  @Test func queuedCommandAttachmentIsAQueuedMessage() {
    expectNoDifference(
      decode(
        #"{"type":"attachment","uuid":"q-1","timestamp":"2026-10-25T15:16:12.607Z","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"Also add a test."}],"source_uuid":"c9d8e7f6-a5b4-4c3d-8e2f-1a0b9c8d7e6f","commandMode":"prompt"}}"#
      ),
      .queuedMessage(uuid: "q-1", text: "Also add a test.")
    )
  }

  @Test func otherAttachmentsAreIgnored() {
    expectNoDifference(
      decode(#"{"type":"attachment","uuid":"q-2","attachment":{"type":"todo_reminder"}}"#),
      .ignored
    )
  }

  @Test func lifecycleLinesAreIgnored() {
    expectNoDifference(
      [
        decode(#"{"type":"system","subtype":"init","session_id":"s","model":"m","cwd":"/"}"#),
        decode(#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#),
        decode(#"{"type":"control_response","response":{"subtype":"success","request_id":"int-1","response":{}}}"#),
      ],
      [.ignored, .ignored, .ignored]
    )
  }

  @Test func transcriptSkipsSidechainAndBookkeeping() throws {
    let lines = try decoded("transcript")
    expectNoDifference(
      lines.map { line -> String in
        switch line {
        case .user(_, _, let isPrompt, _): isPrompt ? "prompt" : "user"
        case .assistant: "assistant"
        case .title(let title): "title:\(title)"
        case .ignored: "ignored"
        default: "other"
        }
      },
      [
        "ignored", "prompt", "ignored", "assistant", "ignored", "user", "assistant", "title:Fix the bug",
        "ignored", "prompt", "assistant", "ignored", "title:Bug fix chat",
      ]
    )
  }

  @Test func transcriptLinesCarryTimestampsAndPlainStringPrompts() throws {
    let lines = try decoded("transcript")
    expectNoDifference(
      lines[1],
      .user(
        uuid: "t-u1", timestamp: Date(timeIntervalSince1970: 1_792_335_600), isPrompt: true,
        blocks: [.text("Fix the bug")]))
    expectNoDifference(
      lines[9],
      .user(
        uuid: "t-u3", timestamp: Date(timeIntervalSince1970: 1_792_335_660), isPrompt: true,
        blocks: [.text("Thanks")]))
  }

  @Test func metaUserLinesAreIgnored() {
    expectNoDifference(
      decode(
        #"{"type":"user","uuid":"m","promptId":"p","isMeta":true,"timestamp":"2026-10-18T15:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /tmp/s"}]}}"#
      ),
      .ignored)
  }

  @Test func slashCommandPromptShowsTheCommandTyped() {
    expectNoDifference(
      [
        decode(
          #"{"type":"user","uuid":"c1","promptId":"p","message":{"role":"user","content":"<command-message>probe-echo</command-message>\n<command-name>/probe-echo</command-name>"}}"#
        ),
        decode(
          #"{"type":"user","uuid":"c2","promptId":"p","message":{"role":"user","content":"<command-name>/context</command-name>\n            <command-message>context</command-message>\n            <command-args></command-args>"}}"#
        ),
        decode(
          #"{"type":"user","uuid":"c3","promptId":"p","message":{"role":"user","content":"<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>the diff</command-args>"}}"#
        ),
      ],
      [
        .user(uuid: "c1", timestamp: nil, isPrompt: true, blocks: [.text("/probe-echo")]),
        .user(uuid: "c2", timestamp: nil, isPrompt: true, blocks: [.text("/context")]),
        .user(uuid: "c3", timestamp: nil, isPrompt: true, blocks: [.text("/review the diff")]),
      ]
    )
  }

  @Test func fractionalSecondsAreKept() {
    let line = decode(
      #"{"type":"assistant","uuid":"x","timestamp":"2026-10-18T15:00:00.250Z","message":{"content":[{"type":"text","text":"hi"}]}}"#)
    expectNoDifference(
      line,
      .assistant(uuid: "x", timestamp: Date(timeIntervalSince1970: 1_792_335_600.25), blocks: [.text("hi")]))
  }

  @Test func toolResultContentArrayJoinsTextAndNamesOtherBlocks() {
    let line = decode(
      #"{"type":"user","uuid":"u","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":true,"content":[{"type":"text","text":"a"},{"type":"image"}]}]}}"#
    )
    expectNoDifference(
      line,
      .user(
        uuid: "u", timestamp: nil, isPrompt: false,
        blocks: [.toolResult(toolUseID: "t", text: "a\n[image]", isError: true)]))
  }

  @Test func unknownContentBlocksAreSkipped() {
    let line = decode(
      #"{"type":"assistant","uuid":"x","message":{"content":[{"type":"redacted_thinking","data":"zz"},{"type":"text","text":"hi"}]}}"#)
    expectNoDifference(line, .assistant(uuid: "x", timestamp: nil, blocks: [.text("hi")]))
  }

  @Test func supportedTypeThatFailsToDecodeIsGap() {
    expectNoDifference(decode(#"{"type":"assistant","message":42}"#), .gap)
  }

  @Test func notJSONIsGap() {
    expectNoDifference(AgentLine.decode(Data("not json".utf8)), .gap)
  }

  @Test func malformedControlRequestIsGap() {
    expectNoDifference(decode(#"{"type":"control_request","request":7}"#), .gap)
  }

  @Test func canUseToolWithoutInputIsGap() {
    expectNoDifference(
      decode(#"{"type":"control_request","request_id":"r","request":{"subtype":"can_use_tool"}}"#), .gap)
  }

  @Test func failedResultCarriesItsErrors() {
    expectNoDifference(
      decode(#"{"type":"result","subtype":"error_during_execution","duration_ms":9,"is_error":true,"errors":["a","b"]}"#),
      .result(durationMs: 9, isError: true, text: "a\nb"))
  }

  @Test func unknownBlockWithUnexpectedFieldsKeepsItsSiblings() {
    let line = decode(
      #"{"type":"assistant","uuid":"x","message":{"content":[{"type":"novel","content":{"x":1},"text":7},{"type":"text","text":"hi"}]}}"#)
    expectNoDifference(line, .assistant(uuid: "x", timestamp: nil, blocks: [.text("hi")]))
  }

  @Test func toolResultTextBlockWithoutTextIsGap() {
    expectNoDifference(
      decode(#"{"type":"user","uuid":"u","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"text"}]}]}}"#),
      .gap)
  }

  @Test func unknownTypeIsIgnored() {
    expectNoDifference(decode(#"{"type":"rate_limit_event","x":1}"#), .ignored)
  }

  @Test func jsonValueKeepsBoolsAndZeroOneNumbersApart() throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"[true,false,1,0,null,"1"]"#.utf8))
    expectNoDifference(value, .array([.bool(true), .bool(false), .number(1), .number(0), .null, .string("1")]))
  }
}
