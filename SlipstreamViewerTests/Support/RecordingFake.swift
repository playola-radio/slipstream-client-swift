import Foundation
import SlipstreamCore
import Synchronization

@testable import SlipstreamViewer

/// Records every Record and Pause and answers with queued failures, succeeding once the queue is
/// empty. After `hold()`, the next call waits until `release()`.
final class RecordingFake: Sendable {
  enum Call: Equatable {
    case record(String)
    case pause(String, origin: PauseOrigin)
  }

  private struct State {
    var calls: [Call] = []
    var failures: [QuestionError] = []
    var next: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)?
    var held: AsyncStream<Void>.Continuation?
  }

  private let state = Mutex(State())

  var calls: [Call] { state.withLock { $0.calls } }

  func setFailures(_ failures: QuestionError...) { state.withLock { $0.failures = failures } }

  func hold() {
    let next = AsyncStream<Void>.makeStream()
    state.withLock { $0.next = next }
  }

  func release() {
    let held = state.withLock { state in
      defer { state.held = nil }
      return state.held
    }
    held?.finish()
  }

  var client: RecordingClient {
    RecordingClient(
      record: { try await self.perform(.record($0)) },
      pause: { try await self.perform(.pause($0, origin: $1)) }
    )
  }

  private func perform(_ call: Call) async throws {
    let (failure, held) = state.withLock { state in
      state.calls.append(call)
      defer { state.next = nil }
      if let next = state.next { state.held = next.continuation }
      return (state.failures.isEmpty ? nil : state.failures.removeFirst(), state.next?.stream)
    }
    if let held {
      for await _ in held {}
    }
    if let failure { throw failure }
  }
}
