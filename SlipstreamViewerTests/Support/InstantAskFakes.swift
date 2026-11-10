import Clocks
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

  func changeRequest(_ reply: String = "On it.", forkSessionID: String = "fork-1") {
    self.reply(.success(.answer(forkSessionID: forkSessionID, reply: reply, isChangeRequest: true)))
  }

  func report(_ outcome: ReportOutcome, _ reply: String = "Done. It greets a friend now.") {
    self.reply(.success(.report(reply: reply, outcome: outcome)))
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
      throw .unavailable("Claude Code stopped unexpectedly.")
    })
  }
}

/// Answers `QuestionClient.record` and `updateRelay` from scripts, one outcome per call, and keeps
/// every request. Updates succeed once their script runs out; the daemon has no relays until told.
final class RecordFake: Sendable {
  private struct State {
    var requests: [QuestionRequest] = []
    var outcomes: [Result<String, QuestionError>] = []
    var updates: [QuestionRelayUpdateRequest] = []
    var updateOutcomes: [Result<Void, QuestionError>] = []
    var relaySupport: Result<Bool, QuestionError> = .success(false)
    var capabilityChecks: [String] = []
  }

  private let state = Mutex(State())

  var requests: [QuestionRequest] { state.withLock { $0.requests } }
  var updates: [QuestionRelayUpdateRequest] { state.withLock { $0.updates } }
  var capabilityChecks: [String] { state.withLock { $0.capabilityChecks } }

  /// Each outcome is a question id, or the error the daemon gave.
  func script(_ outcomes: Result<String, QuestionError>...) {
    state.withLock { $0.outcomes.append(contentsOf: outcomes) }
  }

  func scriptUpdates(_ outcomes: Result<Void, QuestionError>...) {
    state.withLock { $0.updateOutcomes.append(contentsOf: outcomes) }
  }

  func setRelaySupport(_ support: Result<Bool, QuestionError>) { state.withLock { $0.relaySupport = support } }

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
      },
      updateRelay: { request in
        let outcome = self.state.withLock { state in
          state.updates.append(request)
          return state.updateOutcomes.isEmpty ? .success(()) : state.updateOutcomes.removeFirst()
        }
        try outcome.get()
        return RelayAcknowledgment(
          sessionID: request.sessionID, requestID: request.requestID, questionID: request.questionID,
          relayID: request.relayID, seq: Seq("57")!, duplicate: false)
      },
      supportsRelays: { sessionID in
        try self.state.withLock { state in
          state.capabilityChecks.append(sessionID)
          return state.relaySupport
        }.get()
      }
    )
  }
}

extension InstantAskModel {
  /// Answers with `fork` and records with `recorder`, choosing from `chat`'s tabs.
  static func fake(
    chat: ChatPageModel, fork: ForkFake, recorder: RecordFake = RecordFake(), agent: AgentFake = AgentFake(),
    clock: TestClock<Duration>? = nil
  ) -> InstantAskModel {
    withDependencies {
      $0.agentEnvironment = agent.environmentClient
      $0.askFork = fork.client
      $0.questionClient = recorder.client
      $0.uuid = .incrementing
      if let clock { $0.continuousClock = clock }
    } operation: {
      InstantAskModel(chat: chat)
    }
  }
}
