import CustomDump
import Foundation
import SlipstreamCore
import Testing

enum ForkLines {
  static let forkID = "dbb61fbb-c928-4b33-8d05-dc71e25428e3"
  static let stateRunning = line(#"{"type":"system","subtype":"session_state_changed","state":"running"}"#)
  static func initLine(tools: String = #"["Glob","Grep","Read","StructuredOutput"]"#, servers: String = "[]") -> Data {
    line(#"{"type":"system","subtype":"init","session_id":"\#(forkID)","tools":\#(tools),"mcp_servers":\#(servers),"permissionMode":"default"}"#)
  }
  static let assistant = line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."}]}}"#)
  static func result(_ structured: String = #"{"reply":"greet returns early."}"#, isError: Bool = false, sessionID: String? = forkID) -> Data {
    let session = sessionID.map { #","session_id":"\#($0)""# } ?? ""
    return line(#"{"type":"result","subtype":"success","is_error":\#(isError)\#(session),"structured_output":\#(structured)}"#)
  }
  static func errorResult(result: String) -> Data {
    line(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"\#(result)"}"#)
  }
  static func line(_ text: String) -> Data { Data(text.utf8) }
}

struct ForkOutputTests {
  func read(_ lines: [Data], kind: AskForkKind = .answer(allowsChangeRequests: false)) throws(AskForkError) -> AskForkResult? {
    var output = ForkOutput(kind: kind)
    for line in lines {
      if let result = try output.read(line) { return result }
    }
    return nil
  }

  @Test func parsesAnswerResult() throws {
    expectNoDifference(
      try read([ForkLines.stateRunning, ForkLines.initLine(), ForkLines.assistant, ForkLines.result()]),
      .answer(forkSessionID: ForkLines.forkID, reply: "greet returns early.", isChangeRequest: false)
    )
  }

  @Test func parsesStage2ChangeRequest() throws {
    expectNoDifference(
      try read(
        [ForkLines.initLine(), ForkLines.result(#"{"reply":"On it.","is_change_request":true}"#)],
        kind: .answer(allowsChangeRequests: true)),
      .answer(forkSessionID: ForkLines.forkID, reply: "On it.", isChangeRequest: true)
    )
  }

  func failure(_ lines: [Data], kind: AskForkKind = .answer(allowsChangeRequests: false)) -> AskForkError? {
    do throws(AskForkError) {
      _ = try read(lines, kind: kind)
      return nil
    } catch {
      return error
    }
  }

  @Test func initWithExtraToolNamesTheToolsAndNoServers() {
    expectNoDifference(
      failure([ForkLines.initLine(tools: #"["Bash","Glob","Grep","Read","StructuredOutput"]"#)]),
      .unavailable(
        "The read-only copy of the chat wasn't isolated. It had tools Bash, Glob, Grep, Read, StructuredOutput and MCP servers none.")
    )
  }

  @Test func initWithMcpServerNamesTheServer() {
    expectNoDifference(
      failure([ForkLines.initLine(servers: #"[{"name":"slipstream","status":"connected"},{"name":"other"}]"#)]),
      .unavailable(
        "The read-only copy of the chat wasn't isolated. It had tools Glob, Grep, Read, StructuredOutput and MCP servers slipstream, other.")
    )
  }

  @Test func initWithUnnamedMcpServersCountsThem() {
    expectNoDifference(
      failure([ForkLines.initLine(servers: #"[1,{"status":"connected"}]"#)]),
      .unavailable(
        "The read-only copy of the chat wasn't isolated. It had tools Glob, Grep, Read, StructuredOutput and MCP servers 2.")
    )
  }

  @Test func initWithoutToolListIsUnavailable() {
    expectNoDifference(
      failure([ForkLines.line(#"{"type":"system","subtype":"init","mcp_servers":[]}"#)]),
      .unavailable("The read-only copy of the chat didn't report its tools or MCP servers.")
    )
  }

  @Test func resultBeforeInitIsBadReply() {
    expectNoDifference(
      failure([ForkLines.stateRunning, ForkLines.result()]),
      .badReply("Claude Code answered before reporting its setup.")
    )
  }

  @Test func isErrorResultCarriesClaudesOwnText() {
    expectNoDifference(
      failure([ForkLines.initLine(), ForkLines.errorResult(result: " Invalid API key · Please run /login ")]),
      .unavailable("Claude Code reported an error: Invalid API key · Please run /login")
    )
  }

  @Test func isErrorResultWithoutTextFallsBackToSubtypeThenNoDetails() {
    expectNoDifference(
      failure([ForkLines.initLine(), ForkLines.line(#"{"type":"result","subtype":"error_max_turns","is_error":true}"#)]),
      .unavailable("Claude Code reported an error: error_max_turns")
    )
    expectNoDifference(
      failure([ForkLines.initLine(), ForkLines.result(isError: true)]),
      .unavailable("Claude Code reported an error: no details")
    )
    expectNoDifference(
      failure([ForkLines.initLine(), ForkLines.line(#"{"type":"result","is_error":true,"result":"  "}"#)]),
      .unavailable("Claude Code reported an error: no details")
    )
  }

  @Test func isErrorResultWithoutResultReadsTheErrorsArray() {
    expectNoDifference(
      failure([
        ForkLines.initLine(),
        ForkLines.line(
          #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["", " Tool crashed ","Retry failed"]}"#),
      ]),
      .unavailable("Claude Code reported an error: Tool crashed · Retry failed")
    )
  }

  @Test func isErrorResultTextIsOneBoundedLine() {
    let long = String(repeating: "x", count: 600)
    expectNoDifference(
      failure([ForkLines.initLine(), ForkLines.errorResult(result: #"line one\nline two \#(long)"#)]),
      .unavailable(DiagnosticText.line("Claude Code reported an error: line one line two " + long))
    )
  }

  @Test func isErrorResultBeforeInitStillCarriesClaudesOwnText() {
    expectNoDifference(
      failure([ForkLines.errorResult(result: "Credit balance is too low")]),
      .unavailable("Claude Code reported an error: Credit balance is too low")
    )
  }

  @Test func missingSessionIDIsBadReply() {
    expectNoDifference(
      failure([ForkLines.initLine(), ForkLines.result(sessionID: nil)]), .badReply("The reply had no session id."))
  }

  @Test func missingStructuredOutputIsBadReply() {
    expectNoDifference(
      failure([ForkLines.initLine(), ForkLines.line(#"{"type":"result","is_error":false,"session_id":"\#(ForkLines.forkID)"}"#)]),
      .badReply("The reply had no structured answer. It said nothing.")
    )
  }

  @Test func missingStructuredOutputSaysHowClaudeStoppedAndWhatItSaid() {
    expectNoDifference(
      failure([
        ForkLines.initLine(),
        ForkLines.line(
          #"{"type":"result","subtype":"success","is_error":false,"num_turns":2,"stop_reason":"end_turn","terminal_reason":"completed","result":"It adds\ntwo numbers.","session_id":"\#(ForkLines.forkID)"}"#
        ),
      ]),
      .badReply(
        "The reply had no structured answer (subtype success, turns 2, stop reason end_turn, terminal reason completed). It said: It adds two numbers."
      )
    )
  }

  /// Resuming a chat whose background command was stopped ends an empty turn before the question's.
  @Test func zeroTurnResultFromAStoppedBackgroundTaskIsSkipped() throws {
    expectNoDifference(
      try read([
        ForkLines.line(#"{"type":"system","subtype":"task_notification","status":"stopped"}"#),
        ForkLines.initLine(),
        ForkLines.line(#"{"type":"result","is_error":false,"num_turns":0,"session_id":"\#(ForkLines.forkID)"}"#),
        ForkLines.initLine(),
        ForkLines.result(),
      ]),
      .answer(forkSessionID: ForkLines.forkID, reply: "greet returns early.", isChangeRequest: false)
    )
  }

  @Test func zeroTurnResultWithAnAnswerIsRead() throws {
    expectNoDifference(
      try read([
        ForkLines.initLine(),
        ForkLines.line(
          #"{"type":"result","is_error":false,"num_turns":0,"session_id":"\#(ForkLines.forkID)","structured_output":{"reply":"Yes."}}"#),
      ]),
      .answer(forkSessionID: ForkLines.forkID, reply: "Yes.", isChangeRequest: false)
    )
  }

  @Test func zeroTurnErrorResultIsAnError() {
    expectNoDifference(
      failure([
        ForkLines.initLine(), ForkLines.line(#"{"type":"result","is_error":true,"num_turns":0,"result":"Not logged in"}"#),
      ]),
      .unavailable("Claude Code reported an error: Not logged in")
    )
  }

  @Test func apiRetryKeepsTheLastAPIError() throws {
    var output = ForkOutput(kind: .answer(allowsChangeRequests: false))
    expectNoDifference(output.lastAPIError, nil)
    _ = try output.read(
      ForkLines.line(#"{"type":"system","subtype":"api_retry","attempt":1,"error_status":null,"error":"unknown"}"#))
    expectNoDifference(output.lastAPIError, "unknown")
    _ = try output.read(
      ForkLines.line(
        #"{"type":"system","subtype":"api_retry","attempt":2,"error_status":401,"error":"authentication_failed"}"#))
    expectNoDifference(output.lastAPIError, "401 authentication_failed")
    _ = try output.read(ForkLines.line(#"{"type":"system","subtype":"api_retry","attempt":3,"error_status":null}"#))
    expectNoDifference(output.lastAPIError, "401 authentication_failed")
  }

  @Test func apiRetryStatusOutOfRangeIsLeftOut() throws {
    var output = ForkOutput(kind: .answer(allowsChangeRequests: false))
    _ = try output.read(
      ForkLines.line(#"{"type":"system","subtype":"api_retry","attempt":1,"error_status":1e100,"error":"failure"}"#))
    expectNoDifference(output.lastAPIError, "failure")
  }

  @Test func whitespaceReplyIsBadReply() {
    expectNoDifference(
      failure([ForkLines.initLine(), ForkLines.result(#"{"reply":" \n　"}"#)]), .badReply("The reply was empty."))
  }

  @Test func nonTextReplyIsBadReply() {
    expectNoDifference(
      failure([ForkLines.initLine(), ForkLines.result(#"{"reply":3}"#)]), .badReply("The reply had no text."))
  }

  @Test func extraSchemaFieldIsBadReply() {
    expectNoDifference(
      failure([ForkLines.initLine(), ForkLines.result(#"{"reply":"Yes.","is_change_request":false}"#)]),
      .badReply("The reply had fields other than its text.")
    )
    expectNoDifference(
      failure([ForkLines.initLine(), ForkLines.result(#"{"reply":"Yes."}"#)], kind: .answer(allowsChangeRequests: true)),
      .badReply("The reply had no change-request flag.")
    )
    expectNoDifference(
      failure(
        [ForkLines.initLine(), ForkLines.result(#"{"reply":"Yes.","other":true}"#)], kind: .answer(allowsChangeRequests: true)),
      .badReply("The reply had no change-request flag.")
    )
    expectNoDifference(
      failure(
        [ForkLines.initLine(), ForkLines.result(#"{"reply":"Yes.","is_change_request":true,"other":1}"#)],
        kind: .answer(allowsChangeRequests: true)),
      .badReply("The reply had fields other than its text and change-request flag.")
    )
  }

  @Test func unrelatedLinesAreIgnored() throws {
    expectNoDifference(
      try read([
        ForkLines.stateRunning, ForkLines.line("not json"), ForkLines.line("[1]"), ForkLines.initLine(),
        ForkLines.assistant, ForkLines.line(#"{"type":"rate_limit_event"}"#),
      ]),
      nil
    )
  }

  @Test func parsesReportResult() throws {
    expectNoDifference(
      try read(
        [ForkLines.initLine(), ForkLines.result(#"{"reply":"Done. greet now greets a friend.","outcome":"done"}"#)],
        kind: .report),
      .report(reply: "Done. greet now greets a friend.", outcome: .done)
    )
    expectNoDifference(
      try read([ForkLines.initLine(), ForkLines.result(#"{"reply":"Not yet.","outcome":"not_done_yet"}"#)], kind: .report),
      .report(reply: "Not yet.", outcome: .notDoneYet)
    )
  }

  @Test func reportOutsideItsSchemaIsBadReply() {
    for (structured, detail) in [
      (#"{"reply":"Done.","outcome":"maybe"}"#, "The report had no recognized outcome."),
      (#"{"reply":"Done.","other":"done"}"#, "The report had no recognized outcome."),
      (#"{"reply":"Done."}"#, "The report had no recognized outcome."),
      (#"{"reply":"Done.","outcome":"done","is_change_request":false}"#, "The report had fields other than its reply and outcome."),
    ] {
      expectNoDifference(failure([ForkLines.initLine(), ForkLines.result(structured)], kind: .report), .badReply(detail))
    }
  }
}
