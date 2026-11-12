import CustomDump
import Foundation
import SlipstreamCore
import Testing

private let sessionID = UUID(uuidString: "4BAD416C-1D04-4063-9E76-61EBB936AE06")!

private let baseArguments = [
  "--print", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
  "--thinking=adaptive", "--thinking-display=summarized", "--effort=high", "--model=claude-opus-5-5",
  "--max-turns=1000", "--permission-prompt-tool=stdio", "--permission-mode=bypassPermissions",
  "--disallowedTools=AskUserQuestion", "--setting-sources=user,project,local", "--replay-user-messages",
]

private func json(_ line: Data) throws -> JSONValue {
  #expect(line.last == 0x0A)
  return try JSONDecoder().decode(JSONValue.self, from: line)
}

struct ClaudeInvocationTests {
  @Test func argumentsForNewSession() {
    expectNoDifference(
      ClaudeInvocation.arguments(model: "claude-opus-5-5", effort: "high", session: .new(sessionID)),
      baseArguments + ["--session-id=4bad416c-1d04-4063-9e76-61ebb936ae06"]
    )
  }

  @Test func argumentsForResume() {
    expectNoDifference(
      ClaudeInvocation.arguments(model: "claude-opus-5-5", effort: "high", session: .resume(sessionID)),
      baseArguments + ["--resume=4bad416c-1d04-4063-9e76-61ebb936ae06"]
    )
  }

  @Test func forkArgumentsExact() {
    expectNoDifference(
      ClaudeInvocation.forkArguments(parentSessionID: sessionID, model: "claude-opus-5-5", effort: "high", schema: "{}"),
      [
        "-p", "--resume=4bad416c-1d04-4063-9e76-61ebb936ae06", "--fork-session", "--no-session-persistence",
        "--output-format", "stream-json", "--verbose", "--restricted", "--tools", "Read,Grep,Glob",
        "--strict-mcp-config", "--model=claude-opus-5-5", "--effort=high", "--json-schema", "{}",
      ]
    )
  }

  @Test func workspaceNameArgumentsExact() {
    expectNoDifference(
      ClaudeInvocation.workspaceNameArguments(schema: "{}"),
      [
        "-p", "--model=haiku", "--no-session-persistence", "--max-turns=3", "--tools", "", "--strict-mcp-config",
        "--setting-sources", "", "--output-format", "stream-json", "--verbose", "--json-schema", "{}",
      ]
    )
  }

  @Test func argumentsIncludeReplay() {
    #expect(
      ClaudeInvocation.arguments(model: "claude-opus-5-5", effort: "high", session: .new(sessionID))
        .contains("--replay-user-messages"))
  }

  @Test func userMessageCarriesTopLevelUUIDWhenGiven() throws {
    let relayID = UUID(uuidString: "C9D8E7F6-A5B4-4C3D-8E2F-1A0B9C8D7E6F")!
    expectNoDifference(
      try json(ClaudeInvocation.userMessage("…", uuid: relayID)),
      .object([
        "type": .string("user"),
        "uuid": .string("c9d8e7f6-a5b4-4c3d-8e2f-1a0b9c8d7e6f"),
        "message": .object([
          "role": .string("user"),
          "content": .array([.object(["type": .string("text"), "text": .string("…")])]),
        ]),
      ])
    )
  }

  @Test func ordinaryUserMessageHasNoUUID() throws {
    expectNoDifference(
      try json(ClaudeInvocation.userMessage("Fix \"it\"\nplease / now")),
      .object([
        "type": .string("user"),
        "message": .object([
          "role": .string("user"),
          "content": .array([.object(["type": .string("text"), "text": .string("Fix \"it\"\nplease / now")])]),
        ]),
      ])
    )
  }

  @Test func replyAllowsCanUseToolEchoingInput() throws {
    let input = JSONValue.object(["command": .string("ls"), "depth": .number(2)])
    expectNoDifference(
      try json(ClaudeInvocation.reply(requestID: "req-1", subtype: "can_use_tool", input: input)),
      .object([
        "type": .string("control_response"),
        "response": .object([
          "subtype": .string("success"),
          "request_id": .string("req-1"),
          "response": .object(["behavior": .string("allow"), "updatedInput": input]),
        ]),
      ])
    )
  }

  @Test func replyRejectsUnknownSubtype() throws {
    expectNoDifference(
      try json(ClaudeInvocation.reply(requestID: "req-2", subtype: "hook_callback", input: nil)),
      .object([
        "type": .string("control_response"),
        "response": .object([
          "subtype": .string("error"),
          "request_id": .string("req-2"),
          "error": .string("unsupported"),
        ]),
      ])
    )
  }

  @Test func interruptLine() throws {
    expectNoDifference(
      try json(ClaudeInvocation.interrupt(requestID: "int-1")),
      .object([
        "type": .string("control_request"),
        "request_id": .string("int-1"),
        "request": .object(["subtype": .string("interrupt")]),
      ])
    )
  }
}
