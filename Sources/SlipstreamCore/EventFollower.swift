import Foundation

public struct FollowPolicy: Equatable, Sendable {
  public var maxAttempts = 6
  public var episodeBudget: Duration = .seconds(60)
  public var baseDelay: Duration = .milliseconds(500)
  public var maxDelay: Duration = .seconds(8)
  public var idleTimeout: Duration = .seconds(45)

  public init() {}
}

public enum FollowerStatus: Equatable, Sendable {
  case connecting
  case live
  case reconnecting(attempt: Int)
}

public enum FollowerExit: Equatable, Sendable {
  case cancelled
  case disconnected
  case cursorAhead(durableSeq: Seq?)
  case sessionRemoved
  case sessionNotFound
  case cursorRejected
  case outOfOrder(expected: Seq, received: Seq)
  case malformed(seq: String?, type: String?)
}

public struct IdleTimeout: Error, Equatable, Sendable {}

public struct EventFollower<C: Clock<Duration>>: Sendable {
  public var discover: @Sendable () async throws -> DaemonDescriptor
  public var open: @Sendable (DaemonDescriptor, Seq) -> AsyncThrowingStream<StreamItem, any Error>
  public var clock: C
  public var jitter: @Sendable () -> Double
  public var policy: FollowPolicy

  public init(
    discover: @escaping @Sendable () async throws -> DaemonDescriptor,
    open: @escaping @Sendable (DaemonDescriptor, Seq) -> AsyncThrowingStream<StreamItem, any Error>,
    clock: C,
    jitter: @escaping @Sendable () -> Double,
    policy: FollowPolicy = FollowPolicy()
  ) {
    self.discover = discover
    self.open = open
    self.clock = clock
    self.jitter = jitter
    self.policy = policy
  }

  public func run(
    after start: Seq,
    status: @Sendable (FollowerStatus) async -> Void,
    apply: @Sendable (SlipstreamEvent) async -> Bool
  ) async -> FollowerExit {
    var cursor = start
    var attempt = 0
    var episodeStart: C.Instant?
    await status(.connecting)
    while true {
      var firstItemTimeout = policy.idleTimeout
      if let episodeStart {
        let remaining = policy.episodeBudget - episodeStart.duration(to: clock.now)
        guard remaining > .zero else { return .disconnected }
        firstItemTimeout = min(firstItemTimeout, remaining)
      }
      let outcome = await connectOnce(cursor: &cursor, firstItemTimeout: firstItemTimeout, status: status, apply: apply) {
        attempt = 0
        episodeStart = nil
      }
      if case .exit(let exit) = outcome { return exit }
      if Task.isCancelled { return .cancelled }
      attempt += 1
      let now = clock.now
      let episode = episodeStart ?? now
      episodeStart = episode
      guard attempt <= policy.maxAttempts, episode.duration(to: now) < policy.episodeBudget else {
        return .disconnected
      }
      await status(.reconnecting(attempt: attempt))
      let remaining = policy.episodeBudget - episode.duration(to: now)
      do {
        try await clock.sleep(for: min(delay(forAttempt: attempt), remaining))
      } catch {
        return .cancelled
      }
    }
  }

  private enum Outcome {
    case retry
    case exit(FollowerExit)
  }

  private func connectOnce(
    cursor: inout Seq,
    firstItemTimeout: Duration,
    status: @Sendable (FollowerStatus) async -> Void,
    apply: @Sendable (SlipstreamEvent) async -> Bool,
    resetBudget: () -> Void
  ) async -> Outcome {
    let descriptor: DaemonDescriptor
    do {
      descriptor = try await discover()
    } catch {
      return .retry
    }
    let openedAt = clock.now
    var sawActivity = false
    do {
      for try await item in withIdleTimeout(open(descriptor, cursor), firstItemTimeout: firstItemTimeout) {
        if !sawActivity {
          sawActivity = true
          await status(.live)
        }
        if openedAt.duration(to: clock.now) >= policy.episodeBudget { resetBudget() }
        guard case .frame(let frame) = item else { continue }
        let event: SlipstreamEvent
        do {
          event = try SlipstreamEvent.decode(Data(frame.data.utf8))
        } catch {
          return .exit(.malformed(seq: error.seq ?? frame.id, type: error.type))
        }
        if let id = frame.id, id != event.seq.decimal {
          return .exit(.malformed(seq: id, type: event.type))
        }
        if event.seq <= cursor { continue }
        guard event.seq == cursor.successor else {
          return .exit(.outOfOrder(expected: cursor.successor, received: event.seq))
        }
        guard await apply(event) else { return .exit(.cancelled) }
        cursor = event.seq
        resetBudget()
      }
      return .retry
    } catch DaemonHTTPError.status(let code, let durableSeq) {
      switch code {
      case 409: return .exit(.cursorAhead(durableSeq: durableSeq))
      case 410: return .exit(.sessionRemoved)
      case 404: return .exit(.sessionNotFound)
      case 400: return .exit(.cursorRejected)
      default: return .retry
      }
    } catch {
      return .retry
    }
  }

  private func delay(forAttempt attempt: Int) -> Duration {
    let exponential = policy.baseDelay * (1 << min(attempt - 1, 16))
    let capped = min(exponential, policy.maxDelay)
    return capped * (0.5 + 0.5 * min(max(jitter(), 0), 1))
  }

  private func withIdleTimeout(
    _ upstream: AsyncThrowingStream<StreamItem, any Error>,
    firstItemTimeout: Duration
  ) -> AsyncThrowingStream<StreamItem, any Error> {
    let clock = clock
    let idleTimeout = policy.idleTimeout
    return AsyncThrowingStream { continuation in
      @Sendable func arm(_ timeout: Duration) -> Task<Void, Never> {
        Task {
          guard (try? await clock.sleep(for: timeout)) != nil else { return }
          continuation.finish(throwing: IdleTimeout())
        }
      }
      let reader = Task {
        var watchdog = arm(firstItemTimeout)
        do {
          for try await item in upstream {
            watchdog.cancel()
            continuation.yield(item)
            watchdog = arm(idleTimeout)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
        watchdog.cancel()
      }
      continuation.onTermination = { _ in reader.cancel() }
    }
  }
}
