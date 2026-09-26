import CustomDump
import Foundation
import IdentifiedCollections
import SlipstreamCore
import Testing

enum QuestionFixture {
  static let sha = "6e330444347838f751a500d7adb0cbe7243dcb534d6cf3cce2dbc336bc4ba1fb"
  static let source = QuestionSource(
    context: QuestionContext(changeSeq: "4", path: "user.ts", snapshotSHA256: sha, lineStart: 1, lineEnd: 3),
    selectedText: "export function greet(name: string) {\n  return `hi ${name}`;\n}"
  )

  static func events() throws -> [SlipstreamEvent] {
    let url = try #require(Bundle.module.url(forResource: "question-events", withExtension: "json", subdirectory: "Fixtures"))
    let objects = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
    return try objects.map { try SlipstreamEvent.decode(JSONSerialization.data(withJSONObject: $0)) }
  }

  static func queued(
    _ seq: Int, id: String, text: String = "Why?", replyTo: String? = nil, source: QuestionSource = source
  ) -> SlipstreamEvent {
    SlipstreamEvent(
      seq: Seq(String(seq))!,
      type: "slipstream.question.queued.v1",
      payload: .questionQueued(
        QuestionQueued(questionID: id, text: text, source: source, queuedAtMs: Int64(seq), replyToQuestionID: replyTo)
      )
    )
  }

  static func answered(_ seq: Int, id: String, text: String = "Because.") -> SlipstreamEvent {
    SlipstreamEvent(
      seq: Seq(String(seq))!,
      type: "slipstream.question.answered.v1",
      payload: .questionAnswered(
        QuestionAnswered(questionID: id, attemptSeq: Seq(String(seq - 1))!, text: text, answeredAtMs: Int64(seq))
      )
    )
  }
}

struct QuestionEventDecodingTests {
  @Test func fixtureDecodesTypedQuestionEvents() throws {
    expectNoDifference(
      try QuestionFixture.events().map(\.payload),
      [
        .questionQueued(
          QuestionQueued(
            questionID: "<question_id_1>", text: "Why does greet use a template literal?",
            source: QuestionFixture.source, queuedAtMs: 1_790_428_130_312, replyToQuestionID: nil)
        ),
        .questionQueued(
          QuestionQueued(
            questionID: "<question_id_2>", text: "Is name ever undefined here?",
            source: QuestionFixture.source, queuedAtMs: 1_790_428_130_467, replyToQuestionID: nil)
        ),
        .questionDispatchAttempted(QuestionDispatchAttempted(questionID: "<question_id_1>", queuedSeq: Seq("5")!)),
        .questionAnswered(
          QuestionAnswered(
            questionID: "<question_id_1>", attemptSeq: Seq("7")!,
            text: "It interpolates name into the greeting; a template literal is the idiomatic way.",
            answeredAtMs: 1_790_428_130_772)
        ),
        .questionDispatchAttempted(QuestionDispatchAttempted(questionID: "<question_id_2>", queuedSeq: Seq("6")!)),
        .questionAnswered(
          QuestionAnswered(
            questionID: "<question_id_2>", attemptSeq: Seq("9")!, text: "<16384 bytes of é>",
            answeredAtMs: 1_790_428_131_649)
        ),
      ]
    )
  }

  @Test func followUpCarriesReplyTarget() throws {
    let json = #"""
      {"id":"11","seq":"11","type":"slipstream.question.queued.v1","data":{"session_id":"s","question_id":"q3","request_id":"r","target":{"harness":"codex","harness_session_id":"h","worktree":"/w"},"text":"And then?","context":{"change_seq":"4","path":"user.ts","snapshot_sha256":"6e330444347838f751a500d7adb0cbe7243dcb534d6cf3cce2dbc336bc4ba1fb","line_start":1,"line_end":3,"selected_text":"export function greet(name: string) {\n  return `hi ${name}`;\n}"},"queued_at_ms":1,"expires_at_ms":2,"reply_to_question_id":"q1"}}
      """#
    expectNoDifference(
      try SlipstreamEvent.decode(Data(json.utf8)).payload,
      .questionQueued(
        QuestionQueued(questionID: "q3", text: "And then?", source: QuestionFixture.source, queuedAtMs: 1, replyToQuestionID: "q1")
      )
    )
  }

  @Test(arguments: [
    "slipstream.question.queued.v1",
    "slipstream.question.dispatch_attempted.v1",
    "slipstream.question.answered.v1",
  ])
  func malformedQuestionEventThrowsWithSeqAndType(_ type: String) {
    #expect(throws: EventDecodingError(seq: "7", type: type)) {
      try SlipstreamEvent.decode(Data("{\"id\":\"7\",\"seq\":\"7\",\"type\":\"\(type)\",\"data\":{}}".utf8))
    }
  }

  @Test(arguments: ["", " \n\u{3000}", String(repeating: "é", count: 8193)])
  func answerTextOutsideTheContractThrows(_ text: String) throws {
    let data: [String: Any] = ["question_id": "q1", "attempt_seq": "6", "text": text, "answered_at_ms": 1]
    let envelope: [String: Any] = ["id": "7", "seq": "7", "type": "slipstream.question.answered.v1", "data": data]
    let json = try JSONSerialization.data(withJSONObject: envelope)
    #expect(throws: EventDecodingError(seq: "7", type: "slipstream.question.answered.v1")) {
      try SlipstreamEvent.decode(json)
    }
  }
}

struct QuestionThreadsTests {
  @Test func fixtureFoldsIntoTwoAnsweredThreads() throws {
    expectNoDifference(
      QuestionThreads(try QuestionFixture.events()).threads,
      [
        QuestionThread(
          id: "<question_id_1>", source: QuestionFixture.source,
          turns: [
            QuestionTurn(
              questionID: "<question_id_1>", text: "Why does greet use a template literal?", queuedAtMs: 1_790_428_130_312,
              answer: QuestionAnswer(
                seq: Seq("8")!, text: "It interpolates name into the greeting; a template literal is the idiomatic way.",
                answeredAtMs: 1_790_428_130_772))
          ]
        ),
        QuestionThread(
          id: "<question_id_2>", source: QuestionFixture.source,
          turns: [
            QuestionTurn(
              questionID: "<question_id_2>", text: "Is name ever undefined here?", queuedAtMs: 1_790_428_130_467,
              answer: QuestionAnswer(seq: Seq("10")!, text: "<16384 bytes of é>", answeredAtMs: 1_790_428_131_649))
          ]
        ),
      ]
    )
  }

  @Test func unansweredTurnIsWaiting() {
    let threads = QuestionThreads([QuestionFixture.queued(1, id: "q1")])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.waiting])
  }

  @Test func answerMakesTurnAnswered() {
    var threads = QuestionThreads([QuestionFixture.queued(1, id: "q1")])
    expectDifference(threads.threads) {
      threads.apply(QuestionFixture.answered(3, id: "q1"))
    } changes: {
      $0[id: "q1"]?.turns[0].answer = QuestionAnswer(seq: Seq("3")!, text: "Because.", answeredAtMs: 3)
    }
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.answered])
  }

  @Test func followUpsJoinTheRootThreadWithItsSource() {
    let other = QuestionSource(
      context: QuestionContext(changeSeq: "9", path: "other.ts", snapshotSHA256: QuestionFixture.sha, lineStart: 2, lineEnd: 2),
      selectedText: "x"
    )
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1", text: "First"),
      QuestionFixture.answered(3, id: "q1"),
      QuestionFixture.queued(4, id: "q2", text: "Second", replyTo: "q1", source: other),
      QuestionFixture.answered(6, id: "q2"),
      QuestionFixture.queued(7, id: "q3", text: "Third", replyTo: "q2"),
    ])
    expectNoDifference(threads.threads.ids, ["q1"])
    expectNoDifference(threads.threads[id: "q1"]?.source, QuestionFixture.source)
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.text), ["First", "Second", "Third"])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.answered, .answered, .waiting])
  }

  @Test func threadsAnsweredOutOfOrderKeepAskOrder() {
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.queued(2, id: "q2"),
      QuestionFixture.answered(4, id: "q2"),
    ])
    expectNoDifference(threads.threads.ids, ["q1", "q2"])
    expectNoDifference(threads.threads.map { $0.turns.map(\.status) }, [[.waiting], [.answered]])
  }

  @Test func unknownReplyTargetAndUnknownAnswerAreIgnored() {
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.queued(2, id: "q2", replyTo: "missing"),
      QuestionFixture.answered(4, id: "q2"),
      QuestionFixture.answered(6, id: "missing"),
    ])
    expectNoDifference(threads, QuestionThreads([QuestionFixture.queued(1, id: "q1")]))
  }

  @Test func firstAnswerIsImmutable() {
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.answered(3, id: "q1", text: "First"),
      QuestionFixture.answered(5, id: "q1", text: "Second"),
    ])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.answer?.text), ["First"])
  }

  @Test func repeatedQuestionIDDoesNotAddATurn() {
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.queued(2, id: "q2", replyTo: "q1"),
      QuestionFixture.queued(3, id: "q2", replyTo: "q1"),
      QuestionFixture.queued(4, id: "q1"),
    ])
    expectNoDifference(threads.threads.ids, ["q1"])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.questionID), ["q1", "q2"])
  }

  @Test func liveFollowAfterAnyReplayedPrefixMatchesReplayFromZero() throws {
    let events = try QuestionFixture.events() + [
      QuestionFixture.queued(11, id: "q3", replyTo: "<question_id_1>"),
      QuestionFixture.answered(13, id: "q3"),
    ]
    for split in events.indices {
      var resumed = QuestionThreads(events[..<split])
      for event in events[split...] {
        resumed.apply(event)
      }
      expectNoDifference(resumed, QuestionThreads(events))
    }
  }

  @Test func nonQuestionEventsAreIgnored() {
    let threads = QuestionThreads([
      SlipstreamEvent(seq: Seq("1")!, type: "slipstream.session.started.v1", payload: .sessionStarted(root: "/w")),
      SlipstreamEvent(seq: Seq("2")!, type: "slipstream.future.v1", payload: .unsupported(type: "slipstream.future.v1")),
    ])
    expectNoDifference(threads, QuestionThreads())
  }
}
