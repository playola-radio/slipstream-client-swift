import Foundation
import Synchronization

@testable import SlipstreamViewer

struct SuggestionFailed: Error, Equatable {}

/// Records every suggestion request and answers with the set name, or throws once failure is set.
final class WorkspaceNameSuggestionFake: Sendable {
  private struct State {
    var messages: [String] = []
    var name = "Sidebar Polling Backoff"
    var fails = false
  }

  private let state = Mutex(State())

  var messages: [String] { state.withLock { $0.messages } }

  func setName(_ name: String) { state.withLock { $0.name = name } }
  func setFails() { state.withLock { $0.fails = true } }

  var client: WorkspaceNameSuggestionClient {
    WorkspaceNameSuggestionClient(suggest: { message, environment in
      precondition(environment == AgentFake.environment)
      return try self.state.withLock { state in
        state.messages.append(message)
        if state.fails { throw SuggestionFailed() }
        return state.name
      }
    })
  }
}
