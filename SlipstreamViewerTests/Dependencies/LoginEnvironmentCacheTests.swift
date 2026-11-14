import Clocks
import ConcurrencyExtras
import CustomDump
import Foundation
import Testing

@testable import SlipstreamViewer

@Suite(.serialized, .mainSerialExecutor)
struct LoginEnvironmentCacheTests {
  let clock = TestClock()
  let shells = LockIsolated(0)

  /// Each load takes one second on the test clock and returns which shell produced it.
  func cache(failing: Set<Int> = []) -> LoginEnvironmentCache {
    LoginEnvironmentCache { [clock, shells] in
      let shell = shells.withValue { $0 += 1; return $0 }
      try await clock.sleep(for: .seconds(1))
      if failing.contains(shell) { throw AgentEnvironmentError.shellTimedOut }
      return ["SHELL_RUN": "\(shell)"]
    }
  }

  @Test func concurrentFirstCallersShareOneShell() async throws {
    let cache = cache()
    let first = Task { try await cache.resolve() }
    let second = Task { try await cache.resolve() }
    await Task.megaYield()

    await clock.advance(by: .seconds(1))

    let values = [try await first.value, try await second.value]
    expectNoDifference(values, [["SHELL_RUN": "1"], ["SHELL_RUN": "1"]])
    expectNoDifference(shells.value, 1)
  }

  @Test func laterCallsReturnTheCachedValueWithoutWaiting() async throws {
    let cache = cache()
    let first = Task { try await cache.resolve() }
    await clock.advance(by: .seconds(1))
    _ = try await first.value

    let cached = try await cache.resolve()
    expectNoDifference(cached, ["SHELL_RUN": "1"])
  }

  @Test func backgroundRefreshReplacesTheCachedValue() async throws {
    let cache = cache()
    let first = Task { try await cache.resolve() }
    await clock.advance(by: .seconds(1))
    _ = try await first.value
    _ = try await cache.resolve()

    await clock.advance(by: .seconds(1))
    await Task.megaYield()

    let refreshed = try await cache.resolve()
    expectNoDifference(refreshed, ["SHELL_RUN": "2"])
  }

  @Test func callsDuringARefreshShareIt() async throws {
    let cache = cache()
    let first = Task { try await cache.resolve() }
    await clock.advance(by: .seconds(1))
    _ = try await first.value

    _ = try await cache.resolve()
    _ = try await cache.resolve()

    expectNoDifference(shells.value, 2)
  }

  @Test func failureIsNotCached() async throws {
    let cache = cache(failing: [1])
    let first = Task { try await cache.resolve() }
    await clock.advance(by: .seconds(1))
    await #expect(throws: AgentEnvironmentError.shellTimedOut) { try await first.value }

    let second = Task { try await cache.resolve() }
    await clock.advance(by: .seconds(1))

    let retried = try await second.value
    expectNoDifference(retried, ["SHELL_RUN": "2"])
  }

  @Test func concurrentCallersShareAFailureAndTheNextCallRetries() async throws {
    let cache = cache(failing: [1])
    let first = Task { try await cache.resolve() }
    let second = Task { try await cache.resolve() }
    await Task.megaYield()
    await clock.advance(by: .seconds(1))
    await #expect(throws: AgentEnvironmentError.shellTimedOut) { try await first.value }
    await #expect(throws: AgentEnvironmentError.shellTimedOut) { try await second.value }

    let third = Task { try await cache.resolve() }
    await clock.advance(by: .seconds(1))

    let retried = try await third.value
    expectNoDifference(retried, ["SHELL_RUN": "2"])
  }

  @Test func failedRefreshKeepsTheCachedValue() async throws {
    let cache = cache(failing: [2])
    let first = Task { try await cache.resolve() }
    await clock.advance(by: .seconds(1))
    _ = try await first.value
    _ = try await cache.resolve()

    await clock.advance(by: .seconds(1))
    await Task.megaYield()

    let kept = try await cache.resolve()
    expectNoDifference(kept, ["SHELL_RUN": "1"])
  }

  @Test func nextCallRefreshesAgainAfterAFailedRefresh() async throws {
    let cache = cache(failing: [2])
    let first = Task { try await cache.resolve() }
    await clock.advance(by: .seconds(1))
    _ = try await first.value
    _ = try await cache.resolve()
    await clock.advance(by: .seconds(1))
    await Task.megaYield()

    _ = try await cache.resolve()
    await clock.advance(by: .seconds(1))
    await Task.megaYield()

    let refreshed = try await cache.resolve()
    expectNoDifference(refreshed, ["SHELL_RUN": "3"])
  }
}
