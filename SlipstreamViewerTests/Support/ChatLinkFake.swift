import Foundation
import SlipstreamCore
import Synchronization

@testable import SlipstreamViewer

/// Records every link operation and answers with queued outcomes: `.linked` and `.unlinked`
/// once the queue is empty.
final class ChatLinkFake: Sendable {
  enum Call: Equatable {
    case link(folder: String, tabID: UUID, replacing: String?)
    case unlink(folder: String, replacing: String)
  }

  private struct State {
    var calls: [Call] = []
    var outcomes: [LinkOutcome] = []
  }

  private let state = Mutex(State())

  var calls: [Call] { state.withLock { $0.calls } }

  func setOutcomes(_ outcomes: LinkOutcome...) { state.withLock { $0.outcomes = outcomes } }

  var client: ChatLinkClient {
    ChatLinkClient(
      link: { folder, tabID, replacing in
        self.record(.link(folder: folder, tabID: tabID, replacing: replacing), otherwise: .linked)
      },
      unlink: { folder, replacing in
        self.record(.unlink(folder: folder, replacing: replacing), otherwise: .unlinked)
      }
    )
  }

  private func record(_ call: Call, otherwise: LinkOutcome) -> LinkOutcome {
    state.withLock { state in
      state.calls.append(call)
      return state.outcomes.isEmpty ? otherwise : state.outcomes.removeFirst()
    }
  }
}
