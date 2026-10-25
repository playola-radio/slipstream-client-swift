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

  @Test func initWithExtraToolIsUnavailable() {
    #expect(throws: AskForkError.unavailable) {
      try read([ForkLines.initLine(tools: #"["Bash","Glob","Grep","Read","StructuredOutput"]"#)])
    }
  }

  @Test func initWithMcpServerIsUnavailable() {
    #expect(throws: AskForkError.unavailable) {
      try read([ForkLines.initLine(servers: #"[{"name":"slipstream","status":"connected"}]"#)])
    }
  }

  @Test func initWithoutToolListIsUnavailable() {
    #expect(throws: AskForkError.unavailable) {
      try read([ForkLines.line(#"{"type":"system","subtype":"init","mcp_servers":[]}"#)])
    }
  }

  @Test func resultBeforeInitIsUnavailable() {
    #expect(throws: AskForkError.unavailable) { try read([ForkLines.stateRunning, ForkLines.result()]) }
  }

  @Test func isErrorResultIsUnavailable() {
    #expect(throws: AskForkError.unavailable) { try read([ForkLines.initLine(), ForkLines.result(isError: true)]) }
  }

  @Test func missingSessionIDIsBadReply() {
    #expect(throws: AskForkError.badReply) { try read([ForkLines.initLine(), ForkLines.result(sessionID: nil)]) }
  }

  @Test func missingStructuredOutputIsBadReply() {
    #expect(throws: AskForkError.badReply) {
      try read([ForkLines.initLine(), ForkLines.line(#"{"type":"result","is_error":false,"session_id":"\#(ForkLines.forkID)"}"#)])
    }
  }

  @Test func whitespaceReplyIsBadReply() {
    #expect(throws: AskForkError.badReply) { try read([ForkLines.initLine(), ForkLines.result(#"{"reply":" \n　"}"#)]) }
  }

  @Test func extraSchemaFieldIsBadReply() {
    #expect(throws: AskForkError.badReply) {
      try read([ForkLines.initLine(), ForkLines.result(#"{"reply":"Yes.","is_change_request":false}"#)])
    }
    #expect(throws: AskForkError.badReply) {
      try read([ForkLines.initLine(), ForkLines.result(#"{"reply":"Yes."}"#)], kind: .answer(allowsChangeRequests: true))
    }
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
    for structured in [
      #"{"reply":"Done.","outcome":"maybe"}"#, #"{"reply":"Done."}"#,
      #"{"reply":"Done.","outcome":"done","is_change_request":false}"#,
    ] {
      #expect(throws: AskForkError.badReply) { try read([ForkLines.initLine(), ForkLines.result(structured)], kind: .report) }
    }
  }
}
