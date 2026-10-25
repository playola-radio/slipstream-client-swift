import CustomDump
import Foundation
import Testing
@testable import SlipstreamCore

struct QuestionsTests {
  static let session = "11111111-1111-4111-8111-111111111111"
  static let requestID = "22222222-2222-4222-8222-222222222222"
  static let questionID = "33333333-3333-4333-8333-333333333333"
  static var request: QuestionRequest {
    QuestionRequest(sessionID: session, requestID: requestID, text: "Why?", context: QuestionContext(
      changeSeq: "9007199254740993", path: "a.swift", snapshotSHA256: String(repeating: "a", count: 64),
      lineStart: 7, lineEnd: 9))
  }
  static var acknowledgment: String {
    """
    {"v":1,"ok":true,"session_id":"\(session)","request_id":"\(requestID)","question_id":"\(questionID)","seq":"9007199254740994","queued_at_ms":100,"expires_at_ms":1800100,"duplicate":false}
    """
  }

  @Test func requestUsesShippedSnakeCaseContract() throws {
    let data = try Self.request.encoded()
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    expectNoDifference(json["verb"] as? String, "ask")
    expectNoDifference(json["session_id"] as? String, Self.session)
    let context = try #require(json["context"] as? [String: Any])
    expectNoDifference(context["change_seq"] as? String, "9007199254740993")
    expectNoDifference(context["line_start"] as? Int, 7)
    #expect(context["selected_text"] == nil)
  }

  @Test func followUpNamesItsParentOnlyWhenPresent() throws {
    let followUp = QuestionRequest(sessionID: Self.session, requestID: Self.requestID, text: "And?",
      context: Self.request.context, replyToQuestionID: Self.questionID)
    let json = try #require(JSONSerialization.jsonObject(with: followUp.encoded()) as? [String: Any])
    expectNoDifference(json["reply_to_question_id"] as? String, Self.questionID)
    let root = try #require(JSONSerialization.jsonObject(with: Self.request.encoded()) as? [String: Any])
    #expect(root["reply_to_question_id"] == nil)
  }

  @Test func askNamesTheBindingGenerationOnlyWhenPresent() throws {
    let ask = QuestionRequest(sessionID: Self.session, requestID: Self.requestID, text: "Why?",
      context: Self.request.context, verb: .ask(bindingGeneration: "3"))
    let json = try #require(JSONSerialization.jsonObject(with: ask.encoded()) as? [String: Any])
    expectNoDifference(json["binding_generation"] as? String, "3")
    let reply = try #require(JSONSerialization.jsonObject(with: Self.request.encoded()) as? [String: Any])
    #expect(reply["binding_generation"] == nil)
  }

  static func json(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
  static let contextJSON = #"{"change_seq":"9007199254740993","path":"a.swift","snapshot_sha256":"\#(String(repeating: "a", count: 64))","line_start":7,"line_end":9}"#

  @Test func encodesAskUnchanged() throws {
    expectNoDifference(
      try Self.json(Self.request.encoded()),
      try Self.json(Data(#"{"v":1,"verb":"ask","session_id":"\#(Self.session)","request_id":"\#(Self.requestID)","text":"Why?","context":\#(Self.contextJSON)}"#.utf8))
    )
    let followUp = QuestionRequest(
      sessionID: Self.session, requestID: Self.requestID, text: "And?", context: Self.request.context,
      replyToQuestionID: Self.questionID, verb: .ask(bindingGeneration: "3"))
    expectNoDifference(
      try Self.json(followUp.encoded()),
      try Self.json(Data(#"{"v":1,"verb":"ask","session_id":"\#(Self.session)","request_id":"\#(Self.requestID)","text":"And?","context":\#(Self.contextJSON),"reply_to_question_id":"\#(Self.questionID)","binding_generation":"3"}"#.utf8))
    )
  }

  static let parentSessionID = "5896f28c-f4a9-46c2-b481-7ca57e8714a8"
  static let forkSessionID = "7e3431be-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
  static func exchange(answer: String = "It returns early.", replyTo: String? = nil) -> QuestionRequest {
    QuestionRequest(
      sessionID: session, requestID: requestID, text: "Why?", context: request.context, replyToQuestionID: replyTo,
      verb: .recordExchange(
        answerText: answer,
        conversation: ExchangeConversation(parentSessionID: parentSessionID.uppercased(), forkSessionID: forkSessionID)))
  }
  static var exchangeAcknowledgment: String {
    """
    {"v":1,"ok":true,"session_id":"\(session)","request_id":"\(requestID)","question_id":"\(questionID)","seq":"42","duplicate":false}
    """
  }

  @Test func encodesRecordExchangeExactly() throws {
    expectNoDifference(
      try Self.json(Self.exchange(replyTo: Self.questionID).encoded()),
      try Self.json(Data(#"""
        {"v":1,"verb":"record_question_exchange","session_id":"\#(Self.session)","request_id":"\#(Self.requestID)",
         "text":"Why?","context":\#(Self.contextJSON),"answer_text":"It returns early.",
         "conversation":{"harness":"claude-code","parent_session_id":"\#(Self.parentSessionID)","fork_session_id":"\#(Self.forkSessionID)"},
         "reply_to_question_id":"\#(Self.questionID)"}
        """#.utf8))
    )
  }

  @Test func recordExchangeRefusesOverOneMiB() {
    #expect(throws: QuestionError.rejected(code: "PROTOCOL", message: "The request is too large.")) {
      try Self.exchange(answer: String(repeating: "a", count: ControlTransport.maximumMessageBytes)).encoded()
    }
  }

  @Test func decodesExchangeAcknowledgment() throws {
    expectNoDifference(
      try ExchangeAcknowledgment.decode(Data(Self.exchangeAcknowledgment.utf8), for: Self.exchange()),
      ExchangeAcknowledgment(
        sessionID: Self.session, requestID: Self.requestID, questionID: Self.questionID, seq: Seq("42")!, duplicate: false)
    )
  }

  @Test func ackWithOtherRequestIDIsMalformed() {
    let reply = Self.exchangeAcknowledgment.replacingOccurrences(of: Self.requestID, with: Self.questionID)
    #expect(throws: QuestionError.outcomeUnknown) {
      try ExchangeAcknowledgment.decode(Data(reply.utf8), for: Self.exchange())
    }
  }

  @Test func ackWithOtherSessionIDIsMalformed() {
    let reply = Self.exchangeAcknowledgment.replacingOccurrences(of: Self.session, with: Self.questionID)
    #expect(throws: QuestionError.outcomeUnknown) {
      try ExchangeAcknowledgment.decode(Data(reply.utf8), for: Self.exchange())
    }
  }

  @Test(arguments: ["STORAGE_UNAVAILABLE", "INVALID_CONTEXT"])
  func flatErrorReplyDecodes(_ code: String) {
    #expect(throws: QuestionError.rejected(code: code, message: "Refused")) {
      try ExchangeAcknowledgment.decode(
        Data(#"{"v":1,"ok":false,"code":"\#(code)","message":"Refused"}"#.utf8), for: Self.exchange())
    }
  }

  @Test func malformedParentNeverEncodes() {
    let followUp = QuestionRequest(sessionID: Self.session, requestID: Self.requestID, text: "And?",
      context: Self.request.context, replyToQuestionID: "q1")
    #expect(throws: QuestionError.rejected(code: "PROTOCOL", message: "Invalid capture or request identity.")) {
      try followUp.encoded()
    }
  }

  @Test func exactAcknowledgmentIsRequired() throws {
    let reply = try QuestionAcknowledgment.decode(Data(Self.acknowledgment.utf8), for: Self.request)
    expectNoDifference(reply.requestID, Self.requestID)
    expectNoDifference(reply.seq, Seq("9007199254740994"))
    for bad in ["{}", "null", Self.acknowledgment.replacingOccurrences(of: Self.requestID, with: Self.questionID),
                Self.acknowledgment.replacingOccurrences(of: "\"v\":1", with: "\"v\":2"),
                Self.acknowledgment.replacingOccurrences(of: "\"duplicate\":false", with: "\"other\":false")] {
      #expect(throws: QuestionError.outcomeUnknown) {
        try QuestionAcknowledgment.decode(Data(bad.utf8), for: Self.request)
      }
    }
  }

  @Test func rejectionIsPreserved() {
    let code = "QUESTION_LIMIT"
    #expect(throws: QuestionError.rejected(code: code, message: "Rejected")) {
      try QuestionAcknowledgment.decode(Data("{\"v\":1,\"ok\":false,\"code\":\"\(code)\",\"message\":\"Rejected\"}".utf8), for: Self.request)
    }
  }
}

extension QuestionsTests {
  @Test func invalidRangesAndByteLimitsNeverEncode() throws {
    for (start, end) in [(0, 1), (2, 1), (1, 201), (1, Int.max)] {
      let request = QuestionRequest(sessionID: Self.session, requestID: Self.requestID, text: "Why?",
        context: QuestionContext(changeSeq: "1", path: "a", snapshotSHA256: String(repeating: "a", count: 64), lineStart: start, lineEnd: end))
      #expect(throws: (any Error).self) { try request.encoded() }
    }
    for text in [" \n\u{FEFF}", String(repeating: "😀", count: 2049),
                 String(repeating: " ", count: ControlTransport.maximumMessageBytes) + "Why?"] {
      let request = QuestionRequest(sessionID: Self.session, requestID: Self.requestID, text: text, context: Self.request.context)
      #expect(throws: (any Error).self) { try request.encoded() }
    }
    expectNoDifference(QuestionRequest.trim("\u{FEFF}\t why? \r\n"), "why?")
    expectNoDifference(QuestionRequest.trim("\u{0085}"), "\u{0085}")
  }
}
