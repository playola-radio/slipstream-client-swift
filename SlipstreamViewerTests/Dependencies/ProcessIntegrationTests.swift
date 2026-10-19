import ConcurrencyExtras
import CustomDump
import Darwin
import Foundation
import Testing

@testable import SlipstreamViewer

struct ProcessIntegrationTests {
  @Test func timeoutReturnsWhenOperationIgnoresCancellation() async throws {
    let blocker = AsyncGate()

    await #expect(throws: TimedOut.self) {
      try await withTimeout(.milliseconds(10)) { await blocker.wait() }
    }
    await blocker.open()
  }

  @Test func echoesWrittenLines() async throws {
    let handle = try await launchFake("echo")

    try await handle.write(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
    let events = try await collect(handle.events, count: 2)
    await handle.shutdown()

    expectNoDifference(
      events,
      [.line(Data(#"{"echo":{"a":1}}"#.utf8)), .line(Data(#"{"echo":{"b":2}}"#.utf8))]
    )
  }

  @Test func exitCarriesStatusAndStderrTail() async throws {
    let handle = try await launchFake("stderr-then-exit")

    let events = try await collect(handle.events, until: \.isExit)
    await handle.shutdown()

    guard case .exited(let status, let stderrTail) = events.last else {
      Issue.record("Expected an exit, got \(events)")
      return
    }
    #expect(status == 3)
    #expect(stderrTail.utf8.count == 4096)
    #expect(stderrTail.hasSuffix("filler line 099, enough of them to push stderr past four kilobytes\nlast words\n"))
  }

  @Test func shutdownEscalatesToKill() async throws {
    let handle = try await launchFake("ignore-term")
    _ = try await collect(handle.events, count: 1)

    let started = ContinuousClock.now
    try await withTimeout(.seconds(6)) { await handle.shutdown() }
    let elapsed = ContinuousClock.now - started
    let events = try await collect(handle.events, until: \.isExit)

    #expect(elapsed >= .seconds(3))
    #expect(elapsed < .seconds(4))
    expectNoDifference(events.last, .exited(status: 128 + SIGKILL, stderrTail: ""))
  }

  @Test func shutdownKillsChildProcesses() async throws {
    let handle = try await launchFake("spawn-child")
    let events = try await collect(handle.events, count: 1)
    guard case .line(let line) = events.first,
      let child = try JSONSerialization.jsonObject(with: line) as? [String: Int32],
      let pid = child["child"]
    else {
      Issue.record("Expected the child's pid, got \(events)")
      return
    }

    await handle.shutdown()

    try await eventually { kill(pid, 0) == -1 && errno == ESRCH }
  }

  @Test func writeAfterExitThrows() async throws {
    let handle = try await launchFake("stderr-then-exit")
    _ = try await collect(handle.events, until: \.isExit)

    await #expect(throws: AgentProcessError.writeFailed(errno: EPIPE)) {
      try await handle.write(Data("{}\n".utf8))
    }
    await handle.shutdown()
  }

  @Test func writeAfterShutdownThrows() async throws {
    let handle = try await launchFake("echo")
    await handle.shutdown()

    await #expect(throws: AgentProcessError.writeFailed(errno: EPIPE)) {
      try await handle.write(Data("{}\n".utf8))
    }
  }
}

private final class BundleToken {}

private struct TimedOut: Error {}

private actor AsyncGate {
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    continuation?.resume()
    continuation = nil
  }
}

private func launchFake(_ mode: String) async throws -> AgentProcessHandle {
  let script = try #require(Bundle(for: BundleToken.self).path(forResource: "fake-claude", ofType: "sh"))
  return try await AgentProcessClient.liveValue.launch(
    AgentLaunch(
      executable: "/bin/sh",
      arguments: [script, mode],
      environment: ["PATH": "/usr/bin:/bin"],
      directory: NSTemporaryDirectory()
    )
  )
}

private func withTimeout<T: Sendable>(
  _ limit: Duration = .seconds(5), _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    let resumed = LockIsolated(false)
    let finish: @Sendable (Result<T, any Error>) -> Void = { result in
      guard resumed.withValue({ didResume in
        guard !didResume else { return false }
        didResume = true
        return true
      }) else { return }
      continuation.resume(with: result)
    }
    Task {
      do {
        finish(.success(try await operation()))
      } catch {
        finish(.failure(error))
      }
    }
    Task {
      try? await ContinuousClock().sleep(for: limit)
      finish(.failure(TimedOut()))
    }
  }
}

private func collect(
  _ events: AsyncStream<AgentProcessEvent>, until isDone: @escaping @Sendable (AgentProcessEvent) -> Bool
) async throws -> [AgentProcessEvent] {
  try await withTimeout {
    var seen: [AgentProcessEvent] = []
    for await event in events {
      seen.append(event)
      if isDone(event) { break }
    }
    return seen
  }
}

private func collect(_ events: AsyncStream<AgentProcessEvent>, count: Int) async throws -> [AgentProcessEvent] {
  let seen = LockIsolated(0)
  return try await collect(events) { _ in seen.withValue { $0 += 1; return $0 } == count }
}

private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
  try await withTimeout {
    while !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

extension AgentProcessEvent {
  fileprivate var isExit: Bool {
    if case .exited = self { true } else { false }
  }
}
