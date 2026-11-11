import ConcurrencyExtras
import Foundation
import Testing

@testable import SlipstreamViewer

/// Answers `git`/`gh` calls from a script keyed by argument list, and records every call. A
/// held argument list makes its next call wait until `release()`; its answer is taken when the
/// call is made, so changing the script meanwhile doesn't change what the held call returns.
final class RepoCommandFake: Sendable {
  struct Call: Equatable, Sendable {
    var arguments: [String]
    var folder: String
    var timeout: Duration
  }

  let script = LockIsolated<[[String]: CommandResult]>([:])
  private let recorded = LockIsolated<[Call]>([])
  private let held = LockIsolated<(arguments: [String]?, waiting: [CheckedContinuation<Void, Never>])>((nil, []))

  var calls: [Call] { recorded.value }

  func calls(_ arguments: [String]) -> [Call] { calls.filter { $0.arguments == arguments } }

  func set(_ arguments: [String], stdout: String = "", stderr: String = "", ending: CommandResult.Ending = .exit(0)) {
    script.withValue {
      $0[arguments] = CommandResult(
        command: arguments, folder: URL(fileURLWithPath: "/"), ending: ending, stdout: stdout, stderr: stderr)
    }
  }

  func hold(_ arguments: [String]) { held.withValue { $0.arguments = arguments } }

  func release() {
    let waiting = held.withValue { held in
      defer { held = (nil, []) }
      return held.waiting
    }
    for continuation in waiting { continuation.resume() }
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
          guard held.arguments == arguments else { return false }
          held.arguments = nil
          held.waiting.append(continuation)
          return true
        }
        if !isHeld { continuation.resume() }
      }
      return result
    })
  }
}
