import CustomDump
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

struct QuestionFailureTests {
  static let invalidQuestion = "Use a nonempty question of at most 8192 UTF-8 bytes."

  @Test func rejectionAppendsTheDaemonsMessage() {
    expectNoDifference(
      QuestionFailure.reason(QuestionError.rejected(code: "INVALID_QUESTION", message: "question is blank")),
      Self.invalidQuestion + " The daemon said: question is blank."
    )
  }

  @Test func rejectionKeepsTheDaemonsOwnPeriod() {
    expectNoDifference(
      QuestionFailure.reason(QuestionError.rejected(code: "INVALID_QUESTION", message: " Too long. ")),
      Self.invalidQuestion + " The daemon said: Too long."
    )
  }

  @Test func rejectionCapsTheCompletedDetail() {
    expectNoDifference(
      QuestionFailure.reason(QuestionError.rejected(code: "INVALID_QUESTION", message: String(repeating: "x", count: 600))),
      DiagnosticText.line(Self.invalidQuestion + " The daemon said: " + String(repeating: "x", count: 600) + ".")
    )
  }

  @Test func unknownCodeAppendsTheMessageAfterTheCode() {
    expectNoDifference(
      QuestionFailure.reason(QuestionError.rejected(code: "NEW_CODE", message: "something new")),
      "This question couldn't be accepted (NEW_CODE). The daemon said: something new."
    )
  }

  @Test(arguments: ["", "  \n", Self.invalidQuestion])
  func rejectionDoesNotDuplicateAnEmptyOrIdenticalMessage(message: String) {
    expectNoDifference(
      QuestionFailure.reason(QuestionError.rejected(code: "INVALID_QUESTION", message: message)),
      Self.invalidQuestion
    )
  }

  @Test func otherErrorsAreUnchanged() {
    expectNoDifference(
      QuestionFailure.reason(QuestionError.unavailable),
      "The question service isn't available. Attach the agent session through the shared daemon, then retry."
    )
    expectNoDifference(
      QuestionFailure.reason(QuestionError.outcomeUnknown),
      "The daemon's response wasn't received or couldn't be verified."
    )
  }

  @Test func messageStillAddsTheDraftNote() {
    expectNoDifference(
      QuestionFailure.message(
        QuestionError.rejected(code: "QUESTION_LIMIT", message: "full"), hasUncertainSubmission: false),
      "The question queue is full. Try again later. The daemon said: full. Your draft is kept."
    )
  }
}
