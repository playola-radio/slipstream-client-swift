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

  @Test(arguments: ["SESSION_NOT_SELECTED", "CAPTURE_NOT_READY", "INVALID_CONTEXT", "QUESTION_LIMIT",
                    "STORAGE_UNAVAILABLE", "REQUEST_CONFLICT", "INVALID_QUESTION", "PROTOCOL"])
  func rejectionIsPreserved(_ code: String) {
    #expect(throws: QuestionError.rejected(code: code, message: "Rejected")) {
      try QuestionAcknowledgment.decode(Data("{\"v\":1,\"ok\":false,\"code\":\"\(code)\",\"message\":\"Rejected\"}".utf8), for: Self.request)
    }
  }

  @Test(arguments: ["slipstream.question.queued.v1", "slipstream.question.dispatch_attempted.v1"])
  func questionEventsAreRowlessWithoutInventingPayload(_ type: String) throws {
    let event = try SlipstreamEvent.decode(Data("{\"id\":\"7\",\"seq\":\"7\",\"type\":\"\(type)\",\"data\":{}}".utf8))
    expectNoDifference(event.payload, .recordedWithoutRow)
    expectNoDifference(event.seq, Seq("7"))
  }
}

extension QuestionsTests {
  @Test func invalidRangesAndByteLimitsNeverEncode() throws {
    for (start, end) in [(0, 1), (2, 1), (1, 201), (1, Int.max)] {
      let request = QuestionRequest(sessionID: Self.session, requestID: Self.requestID, text: "Why?",
        context: QuestionContext(changeSeq: "1", path: "a", snapshotSHA256: String(repeating: "a", count: 64), lineStart: start, lineEnd: end))
      #expect(throws: (any Error).self) { try request.encoded() }
    }
    for text in [" \n\u{FEFF}", String(repeating: "😀", count: 2049)] {
      let request = QuestionRequest(sessionID: Self.session, requestID: Self.requestID, text: text, context: Self.request.context)
      #expect(throws: (any Error).self) { try request.encoded() }
    }
    expectNoDifference(QuestionRequest.trim("\u{FEFF}\t why? \r\n"), "why?")
    expectNoDifference(QuestionRequest.trim("\u{0085}"), "\u{0085}")
  }
}
