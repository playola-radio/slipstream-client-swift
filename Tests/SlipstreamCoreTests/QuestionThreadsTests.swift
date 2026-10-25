import CustomDump
import Foundation
import IdentifiedCollections
import SlipstreamCore
import Testing

enum QuestionFixture {
  static let sha = "6e330444347838f751a500d7adb0cbe7243dcb534d6cf3cce2dbc336bc4ba1fb"
  static let boundaryAnswerText = String(repeating: "é", count: 8192)
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
        QuestionQueued(
          questionID: id, requestID: "r-\(id)", text: text, source: source, queuedAtMs: Int64(seq),
          replyToQuestionID: replyTo)
      )
    )
  }

  static func attempted(_ seq: Int, id: String) -> SlipstreamEvent {
    SlipstreamEvent(
      seq: Seq(String(seq))!,
      type: "slipstream.question.dispatch_attempted.v1",
      payload: .questionDispatchAttempted(QuestionDispatchAttempted(questionID: id, queuedSeq: Seq(String(seq - 1))!))
    )
  }

  static func resumed(_ seq: Int) -> SlipstreamEvent {
    SlipstreamEvent(seq: Seq(String(seq))!, type: "slipstream.session.resumed.v1", payload: .sessionResumed)
  }

  static func unlinked(_ seq: Int, reason: String = "unlinked") -> SlipstreamEvent {
    SlipstreamEvent(
      seq: Seq(String(seq))!, type: "slipstream.agent.unlinked.v1", payload: .agentUnlinked(AgentUnlinked(reason: reason)))
  }

  static func recorded(
    _ seq: Int, id: String, text: String = "Why?", answer: String = "Because.", replyTo: String? = nil,
    chat: String = "chat-1"
  ) -> SlipstreamEvent {
    SlipstreamEvent(
      seq: Seq(String(seq))!,
      type: "slipstream.question.exchange_recorded.v1",
      payload: .questionExchangeRecorded(
        QuestionExchangeRecorded(
          questionID: id, requestID: "r-\(id)", text: text, answerText: answer, chatSessionID: chat, source: source,
          replyToQuestionID: replyTo, recordedAtMs: Int64(seq))
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
            questionID: "<question_id_1>", requestID: "fef3ee16-062c-4b24-8b0c-fd03f663a420",
            text: "Why does greet use a template literal?", source: QuestionFixture.source, queuedAtMs: 1_790_428_130_312, replyToQuestionID: nil)
        ),
        .questionQueued(
          QuestionQueued(
            questionID: "<question_id_2>", requestID: "d0d8add5-27ab-43bc-85a1-68a80267a795",
            text: "Is name ever undefined here?", source: QuestionFixture.source, queuedAtMs: 1_790_428_130_467, replyToQuestionID: nil)
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
            questionID: "<question_id_2>", attemptSeq: Seq("9")!, text: QuestionFixture.boundaryAnswerText,
            answeredAtMs: 1_790_428_131_649)
        ),
      ]
    )
  }

  @Test func boundaryAnswerFixtureIsExactlyTheByteLimit() {
    #expect(QuestionFixture.boundaryAnswerText.utf8.count == 16384)
  }

  @Test func followUpCarriesReplyTarget() throws {
    let json = #"""
      {"id":"11","seq":"11","type":"slipstream.question.queued.v1","data":{"session_id":"s","question_id":"q3","request_id":"r","target":{"harness":"codex","harness_session_id":"h","worktree":"/w"},"text":"And then?","context":{"change_seq":"4","path":"user.ts","snapshot_sha256":"6e330444347838f751a500d7adb0cbe7243dcb534d6cf3cce2dbc336bc4ba1fb","line_start":1,"line_end":3,"selected_text":"export function greet(name: string) {\n  return `hi ${name}`;\n}"},"queued_at_ms":1,"expires_at_ms":2,"reply_to_question_id":"q1"}}
      """#
    expectNoDifference(
      try SlipstreamEvent.decode(Data(json.utf8)).payload,
      .questionQueued(
        QuestionQueued(questionID: "q3", requestID: "r", text: "And then?", source: QuestionFixture.source, queuedAtMs: 1, replyToQuestionID: "q1")
      )
    )
  }

  private static func exchangeRecordedJSON(answer: String) throws -> Data {
    let data: [String: Any] = [
      "session_id": "6f3c1e0a-2b4d-4c8e-9a1f-3d5e7b9c0a12",
      "question_id": "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e",
      "request_id": "0d7e4b52-8a19-4c3f-b6e2-91f0a4c3d8e7",
      "text": "Why does greet use a template literal?",
      "context": [
        "change_seq": "4", "path": "user.ts", "snapshot_sha256": QuestionFixture.sha, "line_start": 1, "line_end": 3,
        "selected_text": QuestionFixture.source.selectedText,
      ],
      "answer_text": answer,
      "recorded_at_ms": 1_790_428_130_772,
      "reply_to_question_id": "a1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e",
      "conversation": [
        "harness": "claude-code", "parent_session_id": "5896f28c-f4a9-46c2-b481-7ca57e8714a8",
        "fork_session_id": "7e3431be-1c2d-4e5f-8a9b-0c1d2e3f4a5b", "reported_by": "client",
      ],
    ]
    let envelope: [String: Any] = [
      "specversion": "1.0", "id": "42", "seq": "42", "type": "slipstream.question.exchange_recorded.v1",
      "datacontenttype": "application/json", "time": "2026-09-26T13:08:50.772Z",
      "source": "urn:slipstream:session:6f3c1e0a-2b4d-4c8e-9a1f-3d5e7b9c0a12",
      "subject": "question/b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e", "data": data,
    ]
    return try JSONSerialization.data(withJSONObject: envelope)
  }

  @Test func decodesExchangeRecorded() throws {
    let answer = String(repeating: "x", count: 20_000) + "  \n"
    expectNoDifference(
      try SlipstreamEvent.decode(Self.exchangeRecordedJSON(answer: answer)).payload,
      .questionExchangeRecorded(
        QuestionExchangeRecorded(
          questionID: "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e", requestID: "0d7e4b52-8a19-4c3f-b6e2-91f0a4c3d8e7",
          text: "Why does greet use a template literal?", answerText: answer,
          chatSessionID: "5896f28c-f4a9-46c2-b481-7ca57e8714a8", source: QuestionFixture.source,
          replyToQuestionID: "a1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e", recordedAtMs: 1_790_428_130_772)
      )
    )
  }

  @Test(arguments: [
    "slipstream.question.queued.v1",
    "slipstream.question.dispatch_attempted.v1",
    "slipstream.question.answered.v1",
    "slipstream.question.exchange_recorded.v1",
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
              questionID: "<question_id_1>", requestID: "fef3ee16-062c-4b24-8b0c-fd03f663a420",
              text: "Why does greet use a template literal?", queuedAtMs: 1_790_428_130_312,
              answer: QuestionAnswer(
                seq: Seq("8")!, text: "It interpolates name into the greeting; a template literal is the idiomatic way.",
                answeredAtMs: 1_790_428_130_772))
          ]
        ),
        QuestionThread(
          id: "<question_id_2>", source: QuestionFixture.source,
          turns: [
            QuestionTurn(
              questionID: "<question_id_2>", requestID: "d0d8add5-27ab-43bc-85a1-68a80267a795",
              text: "Is name ever undefined here?", queuedAtMs: 1_790_428_130_467,
              answer: QuestionAnswer(seq: Seq("10")!, text: QuestionFixture.boundaryAnswerText, answeredAtMs: 1_790_428_131_649))
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

  @Test func aQuestionNotYetDispatchedWhenRecordingResumesIsNotDelivered() {
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.resumed(2),
    ])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.notDelivered])
  }

  @Test func aQuestionDispatchedBeforeTheResumeKeepsWaitingAndCanStillBeAnswered() {
    var threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.attempted(2, id: "q1"),
      QuestionFixture.resumed(3),
    ])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.waiting])
    threads.apply(QuestionFixture.answered(5, id: "q1"))
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.answered])
  }

  @Test func answeredTurnsStayAnsweredAcrossAResume() {
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.attempted(2, id: "q1"),
      QuestionFixture.answered(3, id: "q1"),
      QuestionFixture.resumed(4),
    ])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.answered])
  }

  @Test func onlyQuestionsQueuedBeforeTheLatestResumeAreNotDelivered() {
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.resumed(2),
      QuestionFixture.queued(3, id: "q2"),
      QuestionFixture.resumed(4),
      QuestionFixture.queued(5, id: "q3"),
    ])
    expectNoDifference(threads.threads.map { $0.turns.map(\.status) }, [[.notDelivered], [.notDelivered], [.waiting]])
  }

  @Test func aFollowUpAfterAnUndeliveredTurnJoinsTheThreadAndWaits() {
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1", text: "First"),
      QuestionFixture.attempted(2, id: "q1"),
      QuestionFixture.answered(3, id: "q1"),
      QuestionFixture.queued(4, id: "q2", text: "Second", replyTo: "q1"),
      QuestionFixture.resumed(5),
      QuestionFixture.queued(6, id: "q3", text: "Second again", replyTo: "q2"),
    ])
    expectNoDifference(threads.threads.ids, ["q1"])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.answered, .notDelivered, .waiting])
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
      SlipstreamEvent(seq: Seq("1")!, type: "slipstream.session.started.v1", payload: .sessionStarted(SessionStarted(root: "/w", startedAtMs: 0))),
      SlipstreamEvent(seq: Seq("2")!, type: "slipstream.future.v1", payload: .unsupported(type: "slipstream.future.v1")),
    ])
    expectNoDifference(threads, QuestionThreads())
  }
}

extension QuestionThreadsTests {
  @Test func unlinkMarksUnansweredTurnsResending() {
    var threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.attempted(2, id: "q1"),
      QuestionFixture.queued(3, id: "q2"),
    ])
    expectDifference(threads.threads) {
      threads.apply(QuestionFixture.unlinked(4))
    } changes: {
      $0[id: "q1"]?.turns[0].isMoved = true
      $0[id: "q2"]?.turns[0].isMoved = true
    }
    expectNoDifference(threads.threads.map { $0.turns.map(\.status) }, [[.resending], [.resending]])
  }

  @Test func answeredAndNotDeliveredTurnsAreUnaffectedByUnlink() {
    let events = [
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.attempted(2, id: "q1"),
      QuestionFixture.answered(3, id: "q1"),
      QuestionFixture.queued(4, id: "q2"),
      QuestionFixture.resumed(5),
    ]
    expectNoDifference(QuestionThreads(events + [QuestionFixture.unlinked(6)]), QuestionThreads(events))
  }

  @Test func unlinkLeavesQuestionsFromBeforeTheLatestResumeWaiting() {
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.attempted(2, id: "q1"),
      QuestionFixture.resumed(3),
      QuestionFixture.queued(4, id: "q2"),
      QuestionFixture.unlinked(5),
    ])
    expectNoDifference(threads.threads.map { $0.turns.map(\.status) }, [[.waiting], [.resending]])
  }

  @Test(arguments: ["detached", "archived"])
  func otherUnlinkReasonsChangeNothing(_ reason: String) {
    let events = [QuestionFixture.queued(1, id: "q1"), QuestionFixture.attempted(2, id: "q1")]
    expectNoDifference(QuestionThreads(events + [QuestionFixture.unlinked(3, reason: reason)]), QuestionThreads(events))
  }

  @Test func dispatchAfterMoveReturnsToWaiting() {
    var threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.attempted(2, id: "q1"),
      QuestionFixture.unlinked(3),
    ])
    expectDifference(threads.threads) {
      threads.apply(QuestionFixture.attempted(4, id: "q1"))
    } changes: {
      $0[id: "q1"]?.turns[0].isMoved = false
    }
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.waiting])
  }

  @Test func resumeAfterMoveIsNotDelivered() {
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.attempted(2, id: "q1"),
      QuestionFixture.unlinked(3),
      QuestionFixture.resumed(4),
    ])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.notDelivered])
  }

  @Test func lateAnswerAnswersMovedTurn() {
    var threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.attempted(2, id: "q1"),
      QuestionFixture.unlinked(3),
    ])
    threads.apply(QuestionFixture.answered(5, id: "q1"))
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.answered])
  }
}

extension QuestionThreadsTests {
  @Test func hookThreadLinkIsHook() {
    let threads = QuestionThreads([QuestionFixture.queued(1, id: "q1")])
    expectNoDifference(threads.threads[id: "q1"]?.link, .hook)
  }

  @Test func recordedRootStartsRecordedThread() {
    let threads = QuestionThreads([QuestionFixture.recorded(4, id: "q1", text: "Why?", answer: "Because.")])
    expectNoDifference(
      threads.threads,
      [
        QuestionThread(
          id: "q1", source: QuestionFixture.source,
          turns: [
            QuestionTurn(
              questionID: "q1", requestID: "r-q1", text: "Why?", queuedAtMs: 4,
              answer: QuestionAnswer(seq: Seq("4")!, text: "Because.", answeredAtMs: 4))
          ],
          link: .recorded(chatSessionID: "chat-1"))
      ]
    )
  }

  @Test func recordedFollowUpAppendsAnsweredTurn() {
    var threads = QuestionThreads([QuestionFixture.recorded(4, id: "q1")])
    expectDifference(threads.threads) {
      threads.apply(QuestionFixture.recorded(6, id: "q2", text: "And?", answer: "Also.", replyTo: "q1", chat: "chat-2"))
    } changes: {
      $0[id: "q1"]?.turns.append(
        QuestionTurn(
          questionID: "q2", requestID: "r-q2", text: "And?", queuedAtMs: 6,
          answer: QuestionAnswer(seq: Seq("6")!, text: "Also.", answeredAtMs: 6)))
    }
    expectNoDifference(threads.threads[id: "q1"]?.link, .recorded(chatSessionID: "chat-1"))
  }

  @Test func recordedFollowUpWithUnknownParentIgnored() {
    let events = [QuestionFixture.recorded(4, id: "q1")]
    expectNoDifference(
      QuestionThreads(events + [QuestionFixture.recorded(6, id: "q2", replyTo: "missing")]), QuestionThreads(events))
  }

  @Test func recordedFollowUpOnHookThreadIgnored() {
    let events = [QuestionFixture.queued(1, id: "q1"), QuestionFixture.answered(3, id: "q1")]
    expectNoDifference(
      QuestionThreads(events + [QuestionFixture.recorded(6, id: "q2", replyTo: "q1")]), QuestionThreads(events))
  }

  @Test func resumeAndUnlinkLeaveRecordedTurnsAlone() {
    let events = [
      QuestionFixture.recorded(1, id: "q1"),
      QuestionFixture.recorded(2, id: "q2", replyTo: "q1"),
    ]
    let threads = QuestionThreads(
      events + [QuestionFixture.unlinked(3), QuestionFixture.resumed(4), QuestionFixture.unlinked(5)])
    expectNoDifference(threads.threads, QuestionThreads(events).threads)
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.answered, .answered])
  }
}
