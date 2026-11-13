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
    chat: String = "chat-1", relay: ExchangeRelay? = nil
  ) -> SlipstreamEvent {
    SlipstreamEvent(
      seq: Seq(String(seq))!,
      type: "slipstream.question.exchange_recorded.v1",
      payload: .questionExchangeRecorded(
        QuestionExchangeRecorded(
          questionID: id, requestID: "r-\(id)", text: text, answerText: answer, chatSessionID: chat, source: source,
          replyToQuestionID: replyTo, recordedAtMs: Int64(seq), relay: relay)
      )
    )
  }

  static func relayUpdated(_ seq: Int, question: String = "q1", relay: String = "rl1", update: RelayUpdate) -> SlipstreamEvent {
    SlipstreamEvent(
      seq: Seq(String(seq))!,
      type: "slipstream.question.relay_updated.v1",
      payload: .questionRelayUpdated(
        QuestionRelayUpdated(questionID: question, relayID: relay, update: update, recordedAtMs: Int64(seq)))
    )
  }

  static func changed(_ seq: Int, path: String) -> SlipstreamEvent {
    SlipstreamEvent(
      seq: Seq(String(seq))!,
      type: "slipstream.file.changed.v1",
      payload: .fileChanged(FileChange(path: path, before: .absent, after: .absent, observedAtMs: Int64(seq)))
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

  private static func exchangeRecordedJSON(answer: String, relay: [String: Any]? = nil) throws -> Data {
    var data: [String: Any] = [
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
    data["relay"] = relay
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

  @Test func decodesExchangeWithRelay() throws {
    let relay: [String: Any] = [
      "relay_id": "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", "chat_session_id": "5896f28c-f4a9-46c2-b481-7ca57e8714a8",
    ]
    guard case .questionExchangeRecorded(let exchange) = try SlipstreamEvent.decode(
      Self.exchangeRecordedJSON(answer: "On it.", relay: relay)).payload
    else { Issue.record("Not an exchange"); return }
    expectNoDifference(
      exchange.relay,
      ExchangeRelay(relayID: "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", chatSessionID: "5896f28c-f4a9-46c2-b481-7ca57e8714a8"))
  }

  @Test(arguments: [
    (#"{"kind":"sent","chat_session_id":"5896f28c-f4a9-46c2-b481-7ca57e8714a8"}"#,
     RelayUpdate.sent(chatSessionID: "5896f28c-f4a9-46c2-b481-7ca57e8714a8")),
    (#"{"kind":"picked_up"}"#, .pickedUp),
    (#"{"kind":"not_delivered"}"#, .notDelivered),
    (#"{"kind":"reported","outcome":"done","text":"Renamed it."}"#, .reported(.done, text: "Renamed it.")),
    (#"{"kind":"reported","outcome":"not_done_yet","text":"Not yet."}"#, .reported(.notDoneYet, text: "Not yet.")),
  ])
  func decodesRelayUpdated(_ update: String, _ expected: RelayUpdate) throws {
    let json = #"""
      {"specversion":"1.0","id":"43","seq":"43","type":"slipstream.question.relay_updated.v1","datacontenttype":"application/json",
       "time":"2026-09-26T13:08:50.772Z","source":"urn:slipstream:session:6f3c1e0a-2b4d-4c8e-9a1f-3d5e7b9c0a12",
       "subject":"question/b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e",
       "data":{"session_id":"6f3c1e0a-2b4d-4c8e-9a1f-3d5e7b9c0a12","question_id":"b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e",
        "relay_id":"9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d","request_id":"0d7e4b52-8a19-4c3f-b6e2-91f0a4c3d8e7",
        "update":\#(update),"recorded_at_ms":1790428130772}}
      """#
    expectNoDifference(
      try SlipstreamEvent.decode(Data(json.utf8)).payload,
      .questionRelayUpdated(
        QuestionRelayUpdated(
          questionID: "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e", relayID: "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d",
          update: expected, recordedAtMs: 1_790_428_130_772))
    )
  }

  @Test(arguments: [
    "slipstream.question.queued.v1",
    "slipstream.question.dispatch_attempted.v1",
    "slipstream.question.answered.v1",
    "slipstream.question.exchange_recorded.v1",
    "slipstream.question.relay_updated.v1",
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

  @Test func aQuestionDispatchedBeforeTheResumeIsUnconfirmedAndCanStillBeAnswered() {
    var threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.attempted(2, id: "q1"),
      QuestionFixture.resumed(3),
    ])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.unconfirmed])
    threads.apply(QuestionFixture.answered(5, id: "q1"))
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.answered])
  }

  @Test func aQuestionDispatchedAfterTheResumeKeepsWaiting() {
    let threads = QuestionThreads([
      QuestionFixture.resumed(1),
      QuestionFixture.queued(2, id: "q1"),
      QuestionFixture.attempted(3, id: "q1"),
    ])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map(\.status), [.waiting])
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

  @Test func unlinkLeavesQuestionsFromBeforeTheLatestResumeAlone() {
    let threads = QuestionThreads([
      QuestionFixture.queued(1, id: "q1"),
      QuestionFixture.attempted(2, id: "q1"),
      QuestionFixture.resumed(3),
      QuestionFixture.queued(4, id: "q2"),
      QuestionFixture.unlinked(5),
    ])
    expectNoDifference(threads.threads.map { $0.turns.map(\.status) }, [[.unconfirmed], [.resending]])
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

struct QuestionRelayFoldTests {
  static let relay = ExchangeRelay(relayID: "rl1", chatSessionID: "chat-1")

  static func step(_ seq: Int) -> RelayStep { RelayStep(seq: Seq(String(seq))!, atMs: Int64(seq)) }

  static func relays(_ events: [SlipstreamEvent], turn: Int = 0) -> [QuestionRelay]? {
    QuestionThreads(events).threads[id: "q1"]?.turns[turn].relays
  }

  @Test func exchangeWithRelayAddsSentRelay() {
    expectNoDifference(
      Self.relays([QuestionFixture.recorded(4, id: "q1", relay: Self.relay)]),
      [QuestionRelay(id: "rl1", questionID: "q1", chatSessionID: "chat-1", sent: Self.step(4))]
    )
  }

  @Test func sendAgainAddsNewRelayToSameTurn() {
    var threads = QuestionThreads([
      QuestionFixture.recorded(4, id: "q1", relay: Self.relay),
      QuestionFixture.relayUpdated(5, update: .notDelivered),
    ])
    expectDifference(threads.threads[id: "q1"]?.turns[0].relays) {
      threads.apply(QuestionFixture.relayUpdated(6, relay: "rl2", update: .sent(chatSessionID: "chat-2")))
    } changes: {
      $0?.append(QuestionRelay(id: "rl2", questionID: "q1", chatSessionID: "chat-2", sent: Self.step(6)))
    }
  }

  @Test func pickedUpAndReportsFold() {
    var threads = QuestionThreads([QuestionFixture.recorded(4, id: "q1", relay: Self.relay)])
    expectDifference(threads.threads[id: "q1"]?.turns[0].relays[0]) {
      threads.apply(QuestionFixture.relayUpdated(5, update: .pickedUp))
      threads.apply(QuestionFixture.relayUpdated(6, update: .pickedUp))
      threads.apply(QuestionFixture.relayUpdated(7, update: .reported(.notDoneYet, text: "Not yet.")))
    } changes: {
      $0?.pickedUp = Self.step(5)
      $0?.report = RelayReport(outcome: .notDoneYet, text: "Not yet.", seq: Seq("7")!, atMs: 7)
    }
  }

  @Test func doneIsFinal() {
    let events = [
      QuestionFixture.recorded(4, id: "q1", relay: Self.relay),
      QuestionFixture.relayUpdated(5, update: .pickedUp),
      QuestionFixture.changed(6, path: "a.py"),
      QuestionFixture.relayUpdated(7, update: .reported(.done, text: "Renamed it.")),
    ]
    let later = [
      QuestionFixture.relayUpdated(8, update: .notDelivered),
      QuestionFixture.changed(9, path: "b.py"),
      QuestionFixture.relayUpdated(10, update: .reported(.done, text: "Again.")),
    ]
    expectNoDifference(Self.relays(events + later), Self.relays(events))
    expectNoDifference(
      Self.relays(events + later)?[0].status(livePickup: false, liveWrite: false, lastCheckFailed: true), .done)
  }

  @Test func changedPathsAfterSentUntilDone() {
    let relays = Self.relays([
      QuestionFixture.changed(3, path: "a.py"),
      QuestionFixture.recorded(4, id: "q1", relay: Self.relay),
      QuestionFixture.changed(5, path: "c.py"),
      QuestionFixture.changed(6, path: "b.py"),
      QuestionFixture.changed(7, path: "c.py"),
      QuestionFixture.relayUpdated(8, update: .reported(.done, text: "Done.")),
      QuestionFixture.changed(9, path: "d.py"),
    ])
    expectNoDifference(relays?[0].changedPaths, ["c.py", "b.py"])
  }

  @Test func relaysListedPerTurn() {
    let threads = QuestionThreads([
      QuestionFixture.recorded(4, id: "q1", relay: Self.relay),
      QuestionFixture.recorded(5, id: "q2", replyTo: "q1"),
      QuestionFixture.recorded(6, id: "q3", replyTo: "q1", relay: ExchangeRelay(relayID: "rl3", chatSessionID: "chat-1")),
    ])
    expectNoDifference(threads.threads[id: "q1"]?.turns.map { $0.relays.map(\.id) }, [["rl1"], [], ["rl3"]])
  }

  @Test func updateForUnknownRelayIgnored() {
    let events = [QuestionFixture.recorded(4, id: "q1", relay: Self.relay)]
    let threads = QuestionThreads(
      events + [
        QuestionFixture.relayUpdated(5, relay: "missing", update: .pickedUp),
        QuestionFixture.relayUpdated(6, question: "q9", update: .pickedUp),
        QuestionFixture.relayUpdated(7, question: "q9", relay: "rl9", update: .sent(chatSessionID: "chat-1")),
        QuestionFixture.relayUpdated(8, relay: "rl1", update: .sent(chatSessionID: "chat-2")),
      ])
    expectNoDifference(threads, QuestionThreads(events))
  }

  @Test func pickedUpAfterNotDeliveredCountsAsPickedUp() {
    let relay = Self.relays([
      QuestionFixture.recorded(4, id: "q1", relay: Self.relay),
      QuestionFixture.relayUpdated(5, update: .notDelivered),
      QuestionFixture.relayUpdated(6, update: .pickedUp),
    ])?[0]
    expectNoDifference(relay?.isNotDelivered, false)
    expectNoDifference(relay?.status(livePickup: false, liveWrite: false, lastCheckFailed: false), .pickedUp)
  }

  @Test func reportBeforePickupInLogStillFolds() {
    let relay = Self.relays([
      QuestionFixture.recorded(4, id: "q1", relay: Self.relay),
      QuestionFixture.relayUpdated(5, update: .reported(.done, text: "Renamed it.")),
      QuestionFixture.relayUpdated(6, update: .pickedUp),
    ])?[0]
    expectNoDifference(relay?.pickedUp, Self.step(6))
    expectNoDifference(relay?.report, RelayReport(outcome: .done, text: "Renamed it.", seq: Seq("5")!, atMs: 5))
  }

  @Test func doneStaysDoneAfterLaterNotDoneYet() {
    let relay = Self.relays([
      QuestionFixture.recorded(4, id: "q1", relay: Self.relay),
      QuestionFixture.relayUpdated(5, update: .reported(.done, text: "Renamed it.")),
      QuestionFixture.relayUpdated(6, update: .reported(.notDoneYet, text: "Not yet.")),
    ])?[0]
    expectNoDifference(relay?.report, RelayReport(outcome: .done, text: "Renamed it.", seq: Seq("5")!, atMs: 5))
  }
}

struct QuestionRelayStatusTests {
  static let sent = QuestionRelay(
    id: "rl1", questionID: "q1", chatSessionID: "chat-1", sent: QuestionRelayFoldTests.step(4))
  static var pickedUp: QuestionRelay {
    var relay = sent
    relay.pickedUp = QuestionRelayFoldTests.step(5)
    return relay
  }

  @Test func doneWinsOverAFailedCheck() {
    var relay = Self.pickedUp
    relay.report = RelayReport(outcome: .done, text: "Done.", seq: Seq("6")!, atMs: 6)
    expectNoDifference(relay.status(livePickup: false, liveWrite: false, lastCheckFailed: true), .done)
  }

  @Test func failedCheckIsCouldntCheck() {
    var relay = Self.pickedUp
    relay.report = RelayReport(outcome: .notDoneYet, text: "Not yet.", seq: Seq("6")!, atMs: 6)
    expectNoDifference(relay.status(livePickup: false, liveWrite: true, lastCheckFailed: true), .couldntCheck)
  }

  @Test func notDeliveredWinsOverALiveWrite() {
    var relay = Self.sent
    relay.isNotDelivered = true
    expectNoDifference(relay.status(livePickup: false, liveWrite: true, lastCheckFailed: false), .notDelivered)
  }

  @Test func latestNotDoneYetReportIsNotDoneYet() {
    var relay = Self.pickedUp
    relay.changedPaths = ["a.py"]
    relay.lastChangeSeq = Seq("5")
    relay.report = RelayReport(outcome: .notDoneYet, text: "Not yet.", seq: Seq("6")!, atMs: 6)
    expectNoDifference(relay.status(livePickup: false, liveWrite: true, lastCheckFailed: false), .notDoneYet)
  }

  @Test func changedPathsAfterPickupIsWorking() {
    var relay = Self.pickedUp
    relay.changedPaths = ["a.py"]
    relay.lastChangeSeq = Seq("6")
    expectNoDifference(relay.status(livePickup: false, liveWrite: true, lastCheckFailed: false), .working)
  }

  @Test func pickupIsPickedUp() {
    expectNoDifference(Self.pickedUp.status(livePickup: false, liveWrite: false, lastCheckFailed: false), .pickedUp)
  }

  @Test func sentWithoutALiveWriteIsDeliveryUnknown() {
    expectNoDifference(Self.sent.status(livePickup: false, liveWrite: false, lastCheckFailed: false), .deliveryUnknown)
  }

  @Test func sentWithALiveWriteIsSent() {
    expectNoDifference(Self.sent.status(livePickup: false, liveWrite: true, lastCheckFailed: false), .sent)
  }

  @Test func notDoneYetYieldsToLaterFileChange() {
    let relay = QuestionRelayFoldTests.relays([
      QuestionFixture.recorded(4, id: "q1", relay: QuestionRelayFoldTests.relay),
      QuestionFixture.relayUpdated(5, update: .pickedUp),
      QuestionFixture.relayUpdated(6, update: .reported(.notDoneYet, text: "Not yet.")),
      QuestionFixture.changed(7, path: "a.py"),
    ])?[0]
    expectNoDifference(relay?.status(livePickup: false, liveWrite: true, lastCheckFailed: false), .working)
  }

  @Test func livePickupCountsBeforeLogHasIt() {
    expectNoDifference(Self.sent.status(livePickup: true, liveWrite: true, lastCheckFailed: false), .pickedUp)
    var relay = Self.sent
    relay.isNotDelivered = true
    expectNoDifference(relay.status(livePickup: true, liveWrite: true, lastCheckFailed: false), .pickedUp)
  }
}
