import Dependencies
import Foundation
import SlipstreamCore
import Synchronization

@testable import SlipstreamViewer

/// Stands in for the hidden copy: each run waits until the test replies to it. A cancelled run
/// counts as stopped once any held stop is released, like a copy that takes a moment to exit.
final class ForkFake: Sendable {
  private struct State {
    var requests: [AskForkRequest] = []
    var replies: [AsyncStream<Result<AskForkResult, AskForkError>>.Continuation] = []
    var stopCount = 0
    var holdsStops = false
    var heldStops: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  var requests: [AskForkRequest] { state.withLock { $0.requests } }
  var stopCount: Int { state.withLock { $0.stopCount } }

  /// Replies to the most recent run unless another is named.
  func reply(_ outcome: Result<AskForkResult, AskForkError>, to run: Int? = nil) {
    let continuation = state.withLock { $0.replies[run ?? $0.replies.count - 1] }
    continuation.yield(outcome)
    continuation.finish()
  }

  func answer(_ reply: String = "It returns early.", forkSessionID: String = "fork-1", to run: Int? = nil) {
    self.reply(.success(.answer(forkSessionID: forkSessionID, reply: reply, isChangeRequest: false)), to: run)
  }

  func holdStops() { state.withLock { $0.holdsStops = true } }

  func releaseStops() {
    let held = state.withLock { state in
      state.holdsStops = false
      defer { state.heldStops = [] }
      return state.heldStops
    }
    for continuation in held { continuation.resume() }
  }

  var client: AskForkClient {
    AskForkClient(run: { request throws(AskForkError) in
      let (replies, continuation) = AsyncStream<Result<AskForkResult, AskForkError>>.makeStream()
      self.state.withLock { state in
        state.requests.append(request)
        state.replies.append(continuation)
      }
      for await outcome in replies { return try outcome.get() }
      await withCheckedContinuation { continuation in
        let isHeld = self.state.withLock { state in
          if state.holdsStops { state.heldStops.append(continuation) }
          return state.holdsStops
        }
        if !isHeld { continuation.resume() }
      }
      self.state.withLock { $0.stopCount += 1 }
      throw .unavailable
    })
  }
}

/// Answers `QuestionClient.record` from a script, one outcome per call, and keeps every request.
final class RecordFake: Sendable {
  private struct State {
    var requests: [QuestionRequest] = []
    var outcomes: [Result<String, QuestionError>] = []
  }

  private let state = Mutex(State())

  var requests: [QuestionRequest] { state.withLock { $0.requests } }

  /// Each outcome is a question id, or the error the daemon gave.
  func script(_ outcomes: Result<String, QuestionError>...) {
    state.withLock { $0.outcomes.append(contentsOf: outcomes) }
  }

  var client: QuestionClient {
    QuestionClient(
      send: { _ in throw QuestionError.unavailable },
      record: { request in
        let outcome = self.state.withLock { state in
          state.requests.append(request)
          return state.outcomes.isEmpty ? .failure(.outcomeUnknown) : state.outcomes.removeFirst()
        }
        let questionID = try outcome.get()
        return ExchangeAcknowledgment(
          sessionID: request.sessionID, requestID: request.requestID, questionID: questionID, seq: Seq("42")!,
          duplicate: false)
      }
    )
  }
}

extension InstantAskModel {
  /// Answers with `fork` and records with `recorder`, choosing from `chat`'s tabs.
  static func fake(chat: ChatPageModel, fork: ForkFake, recorder: RecordFake = RecordFake()) -> InstantAskModel {
    withDependencies {
      $0.agentEnvironment = AgentFake().environmentClient
      $0.askFork = fork.client
      $0.questionClient = recorder.client
      $0.uuid = .incrementing
    } operation: {
      InstantAskModel(chat: chat)
    }
  }
}
