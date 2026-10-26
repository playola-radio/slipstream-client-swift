import ConcurrencyExtras
import Foundation
@_spi(Internals) import Sharing
import SlipstreamCore
import Synchronization

@testable import SlipstreamViewer

/// A fake terminal runtime and history. Every runtime and history call is logged in order with
/// the `terminals.json` saved at that moment, so tests can check what was persisted first.
final class TerminalFake: Sendable {
  static let environment = TerminalEnvironment(
    variables: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
    shell: "/bin/zsh",
    slipstream: "/opt/slipstream/bin/slipstream"
  )

  enum Call: Equatable {
    case read(UUID)
    case append(UUID)
    case flush(UUID)
    case delete(UUID)
    case launch(directory: String)
    case stop(launch: Int)
  }

  enum Hold { case environment, reads }

  private struct State {
    var calls: [(call: Call, saved: TerminalState?)] = []
    var logs: [UUID: [UInt8]] = [:]
    var missingFolders: Set<String> = []
    var environmentError: TerminalLaunchError?
    var launchError: TerminalLaunchError?
    var launches: [TerminalLaunch] = []
    var continuations: [AsyncStream<TerminalEvent>.Continuation] = []
    var writes: [[UInt8]] = []
    var busy: [Bool] = []
    var holding: Set<Hold> = []
    var held: [Hold: [CheckedContinuation<Void, Never>]] = [:]
  }

  private let state = Mutex(State())
  let files = LockIsolated<[URL: Data]>([:])

  var fileStorage: FileStorage { .inMemory(fileSystem: files) }

  /// `terminals.json` as last saved.
  var saved: TerminalState? {
    files.withValue { files in
      files.values.first.flatMap { try? JSONDecoder().decode(TerminalState.self, from: $0) }
    }
  }

  var calls: [Call] { state.withLock { $0.calls.map(\.call) } }
  var launches: [TerminalLaunch] { state.withLock { $0.launches } }
  func savedState(at call: Call) -> TerminalState? {
    state.withLock { $0.calls.first { $0.call == call }?.saved }
  }
  func log(_ tab: UUID) -> String { String(decoding: state.withLock { $0.logs[tab] ?? [] }, as: UTF8.self) }
  func hasLog(_ tab: UUID) -> Bool { state.withLock { $0.logs[tab] != nil } }
  func writes(_ launch: Int) -> String { String(decoding: state.withLock { $0.writes[launch] }, as: UTF8.self) }

  func setLog(_ tab: UUID, _ text: String) { state.withLock { $0.logs[tab] = Array(text.utf8) } }
  func setMissing(_ folder: String) { state.withLock { _ = $0.missingFolders.insert(folder) } }
  func setEnvironmentError(_ error: TerminalLaunchError?) { state.withLock { $0.environmentError = error } }
  func setLaunchError(_ error: TerminalLaunchError?) { state.withLock { $0.launchError = error } }
  /// Whether the shell of that launch (the most recent unless named) runs a foreground program.
  func setBusy(_ isBusy: Bool, launch: Int? = nil) {
    state.withLock { $0.busy[launch ?? $0.busy.count - 1] = isBusy }
  }

  /// Makes those calls wait until `release(_:)`, like a slow login shell or a slow disk.
  func hold(_ hold: Hold) { state.withLock { _ = $0.holding.insert(hold) } }

  func release(_ hold: Hold) {
    let held = state.withLock { state in
      state.holding.remove(hold)
      return state.held.removeValue(forKey: hold) ?? []
    }
    for continuation in held { continuation.resume() }
  }

  /// Sends output from the most recent launch unless another is named.
  func send(_ text: String, launch: Int? = nil) {
    state.withLock { $0.continuations[launch ?? $0.continuations.count - 1] }.yield(.output(Array(text.utf8)))
  }

  func finish(_ exit: TerminalExit, launch: Int? = nil) {
    let continuation = state.withLock { $0.continuations[launch ?? $0.continuations.count - 1] }
    continuation.yield(.finished(exit))
    continuation.finish()
  }

  var runtimeClient: TerminalRuntimeClient {
    TerminalRuntimeClient(
      environment: {
        await self.wait(.environment)
        if let error = self.state.withLock({ $0.environmentError }) { throw error }
        return Self.environment
      },
      folderExists: { folder in self.state.withLock { !$0.missingFolders.contains(folder) } },
      launch: { launch in
        if let error = self.state.withLock({ $0.launchError }) { throw error }
        let (events, continuation) = AsyncStream<TerminalEvent>.makeStream()
        let index = self.state.withLock { state in
          state.launches.append(launch)
          state.continuations.append(continuation)
          state.writes.append([])
          state.busy.append(false)
          return state.launches.count - 1
        }
        self.record(.launch(directory: launch.directory))
        return TerminalProcessHandle(
          events: events,
          write: { bytes in self.state.withLock { $0.writes[index] += bytes } },
          resize: { _ in },
          isBusy: { self.state.withLock { $0.busy[index] } },
          stop: {
            self.record(.stop(launch: index))
            continuation.yield(.finished(.signalled(SIGHUP)))
            continuation.finish()
          }
        )
      }
    )
  }

  var historyClient: TerminalHistoryClient {
    TerminalHistoryClient(
      read: { tab in
        self.record(.read(tab))
        await self.wait(.reads)
        return self.state.withLock { $0.logs[tab] ?? [] }
      },
      append: { tab, bytes in
        self.record(.append(tab))
        self.state.withLock { $0.logs[tab, default: []] += bytes }
      },
      flush: { tab in self.record(.flush(tab)) },
      delete: { tab in
        self.record(.delete(tab))
        self.state.withLock { _ = $0.logs.removeValue(forKey: tab) }
      }
    )
  }

  private func record(_ call: Call) {
    let saved = saved
    state.withLock { $0.calls.append((call, saved)) }
  }

  private func wait(_ hold: Hold) async {
    await withCheckedContinuation { continuation in
      let isHeld = state.withLock { state in
        if state.holding.contains(hold) { state.held[hold, default: []].append(continuation) }
        return state.holding.contains(hold)
      }
      if !isHeld { continuation.resume() }
    }
  }
}
