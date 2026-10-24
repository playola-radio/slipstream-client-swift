import Foundation
import SlipstreamCore
import Synchronization

@testable import SlipstreamViewer

/// Records every link operation and answers with queued outcomes: `.linked` and `.unlinked`
/// once the queue is empty. After `hold()`, operations wait until `release()`.
final class ChatLinkFake: Sendable {
  enum Call: Equatable {
    case link(folder: String, tabID: UUID, replacing: String?)
    case unlink(folder: String, replacing: String)
  }

  private struct State {
    var calls: [Call] = []
    var outcomes: [LinkOutcome] = []
    var held: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)?
  }

  private let state = Mutex(State())

  var calls: [Call] { state.withLock { $0.calls } }

  func setOutcomes(_ outcomes: LinkOutcome...) { state.withLock { $0.outcomes = outcomes } }

  func hold() {
    let held = AsyncStream<Void>.makeStream()
    state.withLock { $0.held = held }
  }

  func release() {
    let held = state.withLock { state in
      defer { state.held = nil }
      return state.held
    }
    held?.continuation.finish()
  }

  var client: ChatLinkClient {
    ChatLinkClient(
      link: { folder, tabID, replacing in
        await self.record(.link(folder: folder, tabID: tabID, replacing: replacing), otherwise: .linked)
      },
      unlink: { folder, replacing in
        await self.record(.unlink(folder: folder, replacing: replacing), otherwise: .unlinked)
      }
    )
  }

  private func record(_ call: Call, otherwise: LinkOutcome) async -> LinkOutcome {
    let (outcome, held) = state.withLock { state in
      state.calls.append(call)
      return (state.outcomes.isEmpty ? otherwise : state.outcomes.removeFirst(), state.held?.stream)
    }
    if let held {
      for await _ in held {}
    }
    return outcome
  }
}
