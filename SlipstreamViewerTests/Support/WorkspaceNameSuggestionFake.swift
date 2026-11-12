import Foundation
import Synchronization

@testable import SlipstreamViewer

struct SuggestionFailed: Error, Equatable {}

/// Records every suggestion request and answers with a fixed name, or throws once failure is set. After `hold()`, a request waits until its task is cancelled.
final class WorkspaceNameSuggestionFake: Sendable {
  private struct State {
    var messages: [String] = []
    var fails = false
    var gate: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)?
  }

  private let state = Mutex(State())

  var messages: [String] { state.withLock { $0.messages } }

  func setFails() { state.withLock { $0.fails = true } }

  func hold() { state.withLock { $0.gate = AsyncStream<Void>.makeStream() } }

  var client: WorkspaceNameSuggestionClient {
    WorkspaceNameSuggestionClient(suggest: { message, environment in
      precondition(environment == AgentFake.environment)
      let gate = self.state.withLock { state in
        state.messages.append(message)
        return state.gate?.stream
      }
      if let gate {
        for await _ in gate {}
      }
      if self.state.withLock({ $0.fails }) { throw SuggestionFailed() }
      return "Sidebar Polling Backoff"
    })
  }
}
