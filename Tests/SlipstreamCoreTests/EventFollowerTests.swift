import Clocks
import ConcurrencyExtras
import CustomDump
import Foundation
import SlipstreamCore
import Synchronization
import Testing

@Suite(.serialized, .mainSerialExecutor)
struct EventFollowerTests {
  @Test func appliesInOrderAndSkipsDuplicates() async {
    let harness = FollowerHarness([.init([frame(1), frame(2), frame(2), frame(1), frame(3)], .close)])
    let exit = await harness.drive()
    #expect(exit == .sessionRemoved)
    expectNoDifference(harness.applied, [seq(1), seq(2), seq(3)])
  }

  @Test func reconnectsAfterLastAppliedWithRediscoveredDescriptor() async {
    let harness = FollowerHarness(
      [
        .init([frame(1), frame(2)], .close),
        .init([frame(2), frame(3)], .close),
      ],
      tokens: ["first", "second", "third"]
    )
    let exit = await harness.drive()
    #expect(exit == .sessionRemoved)
    expectNoDifference(harness.applied, [seq(1), seq(2), seq(3)])
    expectNoDifference(
      harness.opens,
      [Open(token: "first", cursor: .zero), Open(token: "second", cursor: seq(2)), Open(token: "third", cursor: seq(3))]
    )
  }

  @Test func startsFromTheGivenCursor() async {
    let harness = FollowerHarness([.init([frame(5), frame(6)], .close)])
    _ = await harness.drive(after: seq(5))
    expectNoDifference(harness.applied, [seq(6)])
    #expect(harness.opens.first?.cursor == seq(5))
  }

  @Test func gapHaltsAsOutOfOrder() async {
    let harness = FollowerHarness([.init([frame(1), frame(3)], .close)])
    let exit = await harness.drive()
    #expect(exit == .outOfOrder(expected: seq(2), received: seq(3)))
    expectNoDifference(harness.applied, [seq(1)])
  }

  @Test func malformedKnownTypeHalts() async {
    let broken = StreamItem.frame(
      SSEEvent(id: "2", data: #"{"id":"2","seq":"2","type":"slipstream.session.resumed.v1","data":{}}"#)
    )
    let harness = FollowerHarness([.init([frame(1), broken], .close)])
    let exit = await harness.drive()
    #expect(exit == .malformed(seq: "2", type: "slipstream.session.resumed.v1"))
    expectNoDifference(harness.applied, [seq(1)])
  }

  @Test func sseIDDisagreeingWithSeqHalts() async {
    let mismatched = StreamItem.frame(SSEEvent(id: "9", data: eventJSON(1)))
    let harness = FollowerHarness([.init([mismatched], .close)])
    let exit = await harness.drive()
    #expect(exit == .malformed(seq: "9", type: "slipstream.session.resumed.v1"))
    #expect(harness.applied.isEmpty)
  }

  @Test(
    arguments: [
      (409, FollowerExit.cursorAhead(durableSeq: Seq("7"))),
      (410, .sessionRemoved),
      (404, .sessionNotFound),
      (400, .cursorRejected),
    ]
  )
  func terminalHTTPStatusesExit(code: Int, expected: FollowerExit) async {
    let harness = FollowerHarness([.init([], .fail(DaemonHTTPError.status(code, durableSeq: seq(7))))])
    let exit = await harness.drive()
    #expect(exit == expected)
    #expect(harness.opens.count == 1)
  }

  @Test func rejectedApplyStopsTheFollower() async {
    let harness = FollowerHarness([.init([frame(1), frame(2)], .close)], acceptUpTo: 1)
    let exit = await harness.drive()
    #expect(exit == .cancelled)
    expectNoDifference(harness.applied, [seq(1), seq(2)])
    #expect(harness.opens.count == 1)
  }

  @Test func serverErrorIsRetried() async {
    let harness = FollowerHarness([.init([], .fail(DaemonHTTPError.status(500, durableSeq: nil)))])
    let exit = await harness.drive()
    #expect(exit == .sessionRemoved)
    expectNoDifference(harness.statuses, [.connecting, .reconnecting(attempt: 1)])
  }

  @Test func attemptBudgetExhaustsToDisconnected() async {
    let harness = FollowerHarness(Array(repeating: .init([], .fail(URLError(.cannotConnectToHost))), count: 20))
    let exit = await harness.drive()
    #expect(exit == .disconnected)
    expectNoDifference(harness.statuses, [.connecting] + (1...6).map { .reconnecting(attempt: $0) })
    #expect(harness.opens.count == 7)
  }

  @Test func timeBudgetExhaustsToDisconnected() async {
    var policy = FollowPolicy()
    policy.baseDelay = .seconds(30)
    policy.maxDelay = .seconds(60)
    let harness = FollowerHarness(Array(repeating: .init([], .fail(URLError(.cannotConnectToHost))), count: 20))
    let exit = await harness.drive(policy: policy)
    #expect(exit == .disconnected)
    expectNoDifference(harness.statuses, [.connecting, .reconnecting(attempt: 1), .reconnecting(attempt: 2)])
  }

  @Test func silentReconnectsStillDisconnectWithinTheTimeBudget() async {
    let clock = TestClock()
    let harness = FollowerHarness([.init([], .close)] + Array(repeating: .init([], .hang), count: 5))
    let task = Task { await harness.run(clock: clock) }
    await clock.advance(by: .seconds(59))
    expectNoDifference(harness.statuses, [.connecting, .reconnecting(attempt: 1), .reconnecting(attempt: 2)])
    await clock.advance(by: .seconds(1))
    task.cancel()
    #expect(await task.value == .disconnected)
  }

  @Test func discoveryFailureCountsAgainstTheBudget() async {
    let harness = FollowerHarness([], tokens: [])
    let exit = await harness.drive()
    #expect(exit == .disconnected)
    #expect(harness.opens.isEmpty)
  }

  @Test func budgetResetsOnlyAfterAReconnectDeliversSomething() async {
    let flaky = Array(repeating: FollowerHarness.Connection([.heartbeat], .fail(URLError(.networkConnectionLost))), count: 10)
    let harness = FollowerHarness(flaky)
    let exit = await harness.drive()
    #expect(exit == .sessionRemoved)
    #expect(!harness.statuses.contains(.reconnecting(attempt: 2)))
    #expect(harness.statuses.filter { $0 == .live }.count == 10)
  }

  @Test func silenceForTheIdleTimeoutReconnects() async {
    let clock = TestClock()
    let harness = FollowerHarness([.init([], .hang)])
    let task = Task { await harness.run(clock: clock) }
    await clock.advance(by: .seconds(44))
    expectNoDifference(harness.statuses, [.connecting])
    await clock.advance(by: .seconds(1))
    expectNoDifference(harness.statuses, [.connecting, .reconnecting(attempt: 1)])
    task.cancel()
    #expect(await task.value == .cancelled)
  }

  @Test func heartbeatRearmsTheIdleTimeout() async {
    let clock = TestClock()
    let harness = FollowerHarness([.init([], .hang)])
    let task = Task { await harness.run(clock: clock) }
    await clock.advance(by: .seconds(30))
    harness.send(.heartbeat)
    await clock.advance(by: .seconds(30))
    expectNoDifference(harness.statuses, [.connecting, .live])
    await clock.advance(by: .seconds(15))
    expectNoDifference(harness.statuses, [.connecting, .live, .reconnecting(attempt: 1)])
    task.cancel()
    #expect(await task.value == .cancelled)
  }
}

struct Open: Equatable {
  var token: String
  var cursor: Seq
}

final class FollowerHarness: Sendable {
  enum Ending: Sendable {
    case close
    case fail(any Error)
    case hang
  }

  struct Connection: Sendable {
    var items: [StreamItem]
    var ending: Ending

    init(_ items: [StreamItem], _ ending: Ending) {
      self.items = items
      self.ending = ending
    }
  }

  private struct State {
    var connections: [Connection]
    var tokens: [String]
    var opens: [Open] = []
    var statuses: [FollowerStatus] = []
    var applied: [Seq] = []
    var live: AsyncThrowingStream<StreamItem, any Error>.Continuation?
  }

  private let state: Mutex<State>
  private let acceptUpTo: Int?

  init(_ connections: [Connection], tokens: [String]? = nil, acceptUpTo: Int? = nil) {
    state = Mutex(State(connections: connections, tokens: tokens ?? (0...connections.count).map { "token-\($0)" }))
    self.acceptUpTo = acceptUpTo
  }

  var opens: [Open] { state.withLock { $0.opens } }
  var statuses: [FollowerStatus] { state.withLock { $0.statuses } }
  var applied: [Seq] { state.withLock { $0.applied } }

  func drive(after start: Seq = .zero, policy: FollowPolicy = FollowPolicy()) async -> FollowerExit {
    let clock = TestClock()
    let task = Task { await run(after: start, clock: clock, policy: policy) }
    await clock.run()
    return await task.value
  }

  func send(_ item: StreamItem) {
    _ = state.withLock { $0.live }?.yield(item)
  }

  func run<C: Clock<Duration>>(after start: Seq = .zero, clock: C, policy: FollowPolicy = FollowPolicy()) async -> FollowerExit {
    let follower = EventFollower(
      discover: { [self] in
        try state.withLock { state in
          guard !state.tokens.isEmpty else { throw URLError(.fileDoesNotExist) }
          return DaemonDescriptor(baseURL: URL(string: "http://127.0.0.1:1")!, token: state.tokens.removeFirst())
        }
      },
      open: { [self] descriptor, cursor in
        let (stream, continuation) = AsyncThrowingStream<StreamItem, any Error>.makeStream()
        let connection = state.withLock { state in
          state.opens.append(Open(token: descriptor.token, cursor: cursor))
          return state.connections.isEmpty
            ? Connection([], .fail(DaemonHTTPError.status(410, durableSeq: nil)))
            : state.connections.removeFirst()
        }
        for item in connection.items { continuation.yield(item) }
        switch connection.ending {
        case .close: continuation.finish()
        case .fail(let error): continuation.finish(throwing: error)
        case .hang: state.withLock { $0.live = continuation }
        }
        return stream
      },
      clock: clock,
      jitter: { 1 },
      policy: policy
    )
    let acceptUpTo = acceptUpTo
    return await follower.run(
      after: start,
      status: { [self] status in state.withLock { $0.statuses.append(status) } },
      apply: { [self] event in
        state.withLock { state in
          state.applied.append(event.seq)
          return acceptUpTo.map { state.applied.count <= $0 } ?? true
        }
      }
    )
  }
}

func seq(_ value: Int) -> Seq {
  Seq(String(value))!
}

func eventJSON(_ value: Int) -> String {
  #"{"id":"\#(value)","seq":"\#(value)","type":"slipstream.session.resumed.v1","data":{"session_id":"s"}}"#
}

func frame(_ value: Int) -> StreamItem {
  .frame(SSEEvent(id: String(value), data: eventJSON(value)))
}

struct MainSerialExecutorTrait: TestTrait, SuiteTrait, TestScoping {
  var isRecursive: Bool { true }

  func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    try await withMainSerialExecutor { try await function() }
  }
}

extension Trait where Self == MainSerialExecutorTrait {
  static var mainSerialExecutor: Self { Self() }
}
