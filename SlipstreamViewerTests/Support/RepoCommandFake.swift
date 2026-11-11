import ConcurrencyExtras
import Foundation
import Testing

@testable import SlipstreamViewer

/// Answers `git`/`gh` calls from a script keyed by argument list, and records every call. A
/// held argument list makes its next call wait until `release(_:)`; its answer is taken when the
/// call is made, so changing the script meanwhile doesn't change what the held call returns.
final class RepoCommandFake: Sendable {
  struct Call: Equatable, Sendable {
    var arguments: [String]
    var folder: String
    var timeout: Duration
  }

  let script = LockIsolated<[[String]: CommandResult]>([:])
  private let recorded = LockIsolated<[Call]>([])
  private struct Held {
    var armed: Set<[String]> = []
    var waiting: [(arguments: [String], continuation: CheckedContinuation<Void, Never>)] = []
  }

  private let held = LockIsolated(Held())

  var calls: [Call] { recorded.value }

  func calls(_ arguments: [String]) -> [Call] { calls.filter { $0.arguments == arguments } }

  func set(_ arguments: [String], stdout: String = "", stderr: String = "", ending: CommandResult.Ending = .exit(0)) {
    script.withValue {
      $0[arguments] = CommandResult(
        command: arguments, folder: URL(fileURLWithPath: "/"), ending: ending, stdout: stdout, stderr: stderr)
    }
  }

  func hold(_ arguments: [String]) { held.withValue { _ = $0.armed.insert(arguments) } }

  /// Releases the held calls with these arguments, or every held call.
  func release(_ arguments: [String]? = nil) {
    let released = held.withValue { held in
      let isReleased = { (call: (arguments: [String], continuation: CheckedContinuation<Void, Never>)) in
        arguments == nil || call.arguments == arguments
      }
      defer {
        held.waiting.removeAll(where: isReleased)
        if let arguments { held.armed.remove(arguments) } else { held.armed = [] }
      }
      return held.waiting.filter(isReleased)
    }
    for call in released { call.continuation.resume() }
  }

  var client: RepoCommandClient {
    RepoCommandClient(run: { arguments, folder, timeout in
      self.recorded.withValue { $0.append(Call(arguments: arguments, folder: folder.path, timeout: timeout)) }
      guard var result = self.script.value[arguments] else {
        Issue.record("Unscripted command: \(arguments)")
        return CommandResult(
          command: arguments, folder: folder, ending: .launchFailed("unscripted"), stdout: "", stderr: "")
      }
      result.command = arguments
      result.folder = folder
      await withCheckedContinuation { continuation in
        let isHeld = self.held.withValue { held in
          guard held.armed.remove(arguments) != nil else { return false }
          held.waiting.append((arguments, continuation))
          return true
        }
        if !isHeld { continuation.resume() }
      }
      return result
    })
  }
}
