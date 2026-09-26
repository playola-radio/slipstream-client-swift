import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct QuestionThreadPageTests {
  let storage = InMemoryStorage()

  static let key = QuestionThreadKey(storeID: "store-a", sessionID: Fixture.session, rootQuestionID: "q1")
  static let answered = QuestionTurn(
    questionID: "q1", text: "Why?", queuedAtMs: Fixture.observedAtMs,
    answer: QuestionAnswer(seq: Fixture.seq(3), text: "Because.", answeredAtMs: Fixture.observedAtMs))
  static let waiting = QuestionTurn(questionID: "q2", text: "And then?", queuedAtMs: Fixture.observedAtMs)

  static func source(lines: ClosedRange<Int> = 7...9) -> QuestionSource {
    QuestionSource(
      context: QuestionContext(
        changeSeq: "1", path: "src/types/user.ts", snapshotSHA256: Fixture.shaB,
        lineStart: lines.lowerBound, lineEnd: lines.upperBound),
      selectedText: "a")
  }

  func makeModel(
    _ turns: [QuestionTurn], source: QuestionSource = source(), timeZone: String = "UTC"
  ) -> QuestionThreadPageModel {
    withDependencies {
      $0.defaultInMemoryStorage = storage
      $0.timeZone = TimeZone(identifier: timeZone)!
    } operation: {
      QuestionThreadPageModel(key: Self.key, thread: QuestionThread(id: "q1", source: source, turns: turns))
    }
  }

  func readAnswers() -> Set<AnswerReadMarker> {
    withDependencies { $0.defaultInMemoryStorage = storage } operation: {
      @Shared(.readAnswers) var readAnswers
      return readAnswers
    }
  }

  @Test func sourceLineCountsQuestionsAndAnswers() {
    expectNoDifference(makeModel([Self.answered, Self.waiting]).sourceText, "user.ts:7–9 · 3 messages")
  }

  @Test func singleLineSourceShowsOneLineNumber() {
    expectNoDifference(makeModel([Self.waiting], source: Self.source(lines: 7...7)).sourceText, "user.ts:7 · 1 message")
  }

  @Test func agentTimeUsesTheInjectedTimeZone() throws {
    let answer = try #require(Self.answered.answer)
    expectNoDifference(makeModel([Self.answered]).agentText(answer), "AGENT · 10:42")
    expectNoDifference(makeModel([Self.answered], timeZone: "America/Chicago").agentText(answer), "AGENT · 05:42")
  }

  @Test func followUpIsDisabledWhileTheLatestTurnWaits() {
    let model = makeModel([Self.answered, Self.waiting])
    #expect(model.isFollowUpDisabled)
    model.draft = "Ignored"
    expectNoDifference(model.draft, "")
    model.threadUpdated(QuestionThread(id: "q1", source: Self.source(), turns: [Self.answered]))
    #expect(!model.isFollowUpDisabled)
    model.draft = "Kept"
    expectNoDifference(model.draft, "Kept")
  }

  @Test func displayingAnAnswerMarksOnlyThatAnswerRead() {
    let model = makeModel([Self.answered, Self.waiting])
    model.answerDisplayed(Fixture.seq(99))
    #expect(readAnswers().isEmpty)
    model.answerDisplayed(Fixture.seq(3))
    expectNoDifference(readAnswers(), [AnswerReadMarker(storeID: "store-a", sessionID: Fixture.session, seq: Fixture.seq(3))])
  }
}
