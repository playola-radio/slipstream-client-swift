import ConcurrencyExtras
import CustomDump
import Foundation
import SlipstreamCore
import Synchronization
import Testing

@testable import SlipstreamViewer

@Suite(.serialized)
struct ChatLinkClientTests {
  static let tab = UUID(uuidString: "0B8E6C52-1F3A-4D2B-9C1E-7A5F3E2D1C0B")!
  static let other = UUID(uuidString: "5C1E7A2B-0000-4000-8000-000000000001")!
  static let attachTab = ["attach", "/w", "--store", "/tmp/store"]
  static let unlinkCapture = ["unlink", "--session", "capture-1", "--store", "/tmp/store"]

  @Test func autoLinkSkipsWhenLiveBindingExists() async {
    let fake = LinkFake(binding: CaptureBinding(generation: "3", state: .connected, harnessSessionID: "outside"))

    let outcome = await fake.operations.link(folder: "/w", tabID: Self.tab, replacing: nil)

    expectNoDifference(outcome, .skipped)
    expectNoDifference(fake.calls, [.captures])
  }

  @Test func autoLinkSkipsWhenBindingIsUnavailable() async {
    let fake = LinkFake(binding: CaptureBinding(generation: "3", state: .unavailable, harnessSessionID: "outside"))

    let outcome = await fake.operations.link(folder: "/w", tabID: Self.tab, replacing: nil)

    expectNoDifference(outcome, .skipped)
    expectNoDifference(fake.calls, [.captures])
  }

  @Test func autoLinkAttachesWhenUnlinked() async {
    let fake = LinkFake(binding: CaptureBinding(generation: "3", state: .unlinked, harnessSessionID: "old"))

    let outcome = await fake.operations.link(folder: "/w", tabID: Self.tab, replacing: nil)

    expectNoDifference(outcome, .linked)
    expectNoDifference(fake.calls, [.captures, .run(Self.attachTab)])
  }

  @Test func autoLinkAttachesWhenTheFolderHasNoCapture() async {
    let fake = LinkFake(binding: nil, hasCapture: false)

    let outcome = await fake.operations.link(folder: "/w", tabID: Self.tab, replacing: nil)

    expectNoDifference(outcome, .linked)
    expectNoDifference(fake.calls, [.captures, .run(Self.attachTab)])
  }

  @Test func theLiveCaptureSpeaksForAFolderRecordedBefore() async {
    let fake = LinkFake(
      binding: CaptureBinding(generation: "3", state: .connected, harnessSessionID: "outside"),
      older: CaptureBinding(generation: "1", state: .unlinked, harnessSessionID: "old"))

    let outcome = await fake.operations.link(folder: "/w", tabID: Self.tab, replacing: "3")

    expectNoDifference(outcome, .linked)
    expectNoDifference(fake.calls, [.captures, .run(Self.unlinkCapture), .run(Self.attachTab)])
  }

  @Test func moveSkipsWhenGenerationChanged() async {
    let fake = LinkFake(binding: CaptureBinding(generation: "4", state: .connected, harnessSessionID: "outside"))

    let outcome = await fake.operations.link(folder: "/w", tabID: Self.tab, replacing: "3")

    expectNoDifference(outcome, .skipped)
    expectNoDifference(fake.calls, [.captures])
  }

  @Test func moveUnlinksThenAttaches() async {
    let fake = LinkFake(binding: CaptureBinding(generation: "3", state: .connected, harnessSessionID: "outside"))

    let outcome = await fake.operations.link(folder: "/w", tabID: Self.tab, replacing: "3")

    expectNoDifference(outcome, .linked)
    expectNoDifference(fake.calls, [.captures, .run(Self.unlinkCapture), .run(Self.attachTab)])
  }

  @Test func moveWithNothingLiveOnlyAttaches() async {
    let fake = LinkFake(binding: CaptureBinding(generation: "3", state: .unlinked, harnessSessionID: "outside"))

    let outcome = await fake.operations.link(folder: "/w", tabID: Self.tab, replacing: "3")

    expectNoDifference(outcome, .linked)
    expectNoDifference(fake.calls, [.captures, .run(Self.attachTab)])
  }

  @Test func unlinkRefusedDoesNotAttach() async {
    let fake = LinkFake(binding: CaptureBinding(generation: "3", state: .connected, harnessSessionID: "outside"))
    fake.setResult("unlink", status: 1, output: "slipstream: STORE_LOCKED: the store is locked\n")

    let outcome = await fake.operations.link(folder: "/w", tabID: Self.tab, replacing: "3")

    expectNoDifference(outcome, .refused(.other("STORE_LOCKED: the store is locked")))
    expectNoDifference(fake.calls, [.captures, .run(Self.unlinkCapture)])
  }

  @Test func unlinkRunsAgainstTheCapture() async {
    let fake = LinkFake(binding: CaptureBinding(generation: "3", state: .setupPending, harnessSessionID: "x"))

    let outcome = await fake.operations.unlink(folder: "/w", replacing: "3")

    expectNoDifference(outcome, .unlinked)
    expectNoDifference(fake.calls, [.captures, .run(Self.unlinkCapture)])
  }

  @Test func unlinkSkipsWhenGenerationChanged() async {
    let fake = LinkFake(binding: CaptureBinding(generation: "4", state: .connected, harnessSessionID: "x"))

    let outcome = await fake.operations.unlink(folder: "/w", replacing: "3")

    expectNoDifference(outcome, .skipped)
    expectNoDifference(fake.calls, [.captures])
  }

  @Test func attachEnvironment() async {
    let fake = LinkFake(binding: nil)

    _ = await fake.operations.link(folder: "/w", tabID: Self.tab, replacing: nil)

    expectNoDifference(
      fake.environments,
      [
        [
          "PATH": "/opt/claude/bin:/usr/bin",
          "CLAUDE_CONFIG_DIR": "/fake/claude-config",
          "CLAUDE_CODE_SESSION_ID": "0b8e6c52-1f3a-4d2b-9c1e-7a5f3e2d1c0b",
          "CLAUDE_CODE_EXECPATH": "/opt/claude/bin/claude",
        ]
      ])
  }

  @Test func environmentFailureIsRefused() async {
    let fake = LinkFake(binding: nil)
    fake.setEnvironmentError(.claudeNotFound)

    let outcome = await fake.operations.link(folder: "/w", tabID: Self.tab, replacing: nil)

    expectNoDifference(outcome, .refused(.other("Couldn't find claude on your login shell's PATH")))
    expectNoDifference(fake.calls, [.captures])
  }

  @Test func operationsRunOneAtATime() async {
    let fake = LinkFake(binding: nil)
    let operations = fake.operations
    fake.holdRuns()

    async let first = operations.link(folder: "/w", tabID: Self.tab, replacing: nil)
    await fake.waitForHeldRun()
    async let second = operations.link(folder: "/w", tabID: Self.other, replacing: nil)
    await Task.megaYield()
    expectNoDifference(fake.calls, [.captures, .run(Self.attachTab)])

    fake.releaseRuns()
    _ = await (first, second)

    expectNoDifference(fake.calls, [.captures, .run(Self.attachTab), .captures, .run(Self.attachTab)])
  }

  @Test func secondOperationSeesFirstResult() async {
    let fake = LinkFake(binding: nil)
    fake.linkOnAttach(CaptureBinding(generation: "1", state: .setupPending, harnessSessionID: Self.tab.uuidString))
    let operations = fake.operations
    fake.holdRuns()

    async let first = operations.link(folder: "/w", tabID: Self.tab, replacing: nil)
    await fake.waitForHeldRun()
    async let second = operations.link(folder: "/w", tabID: Self.other, replacing: nil)
    await Task.megaYield()
    fake.releaseRuns()
    let outcomes = await [first, second]

    expectNoDifference(outcomes, [.linked, .skipped])
    expectNoDifference(fake.calls, [.captures, .run(Self.attachTab), .captures])
  }
}

private final class LinkFake: Sendable {
  enum Call: Equatable { case captures, run([String]) }

  private struct State {
    var older: CaptureSummary?
    var capture: CaptureSummary?
    var bindingAfterAttach: CaptureBinding?
    var calls: [Call] = []
    var environments: [[String: String]] = []
    var results: [String: (status: Int32, output: String)] = [:]
    var environmentError: AgentEnvironmentError?
    var holdingRuns = false
    var heldRuns: [CheckedContinuation<Void, Never>] = []
  }

  private let state: Mutex<State>

  /// `older` is a stopped capture of the same folder, listed first.
  init(binding: CaptureBinding?, hasCapture: Bool = true, older: CaptureBinding? = nil) {
    let capture = CaptureSummary(sessionID: "capture-1", root: "/w", state: .recording, binding: binding)
    let stopped = older.map { CaptureSummary(sessionID: "capture-0", root: "/w", state: .stopped, binding: $0) }
    state = Mutex(State(older: stopped, capture: hasCapture ? capture : nil))
  }

  var calls: [Call] { state.withLock { $0.calls } }
  var environments: [[String: String]] { state.withLock { $0.environments } }

  func setResult(_ command: String, status: Int32, output: String) {
    state.withLock { $0.results[command] = (status, output) }
  }

  func setEnvironmentError(_ error: AgentEnvironmentError) { state.withLock { $0.environmentError = error } }
  func linkOnAttach(_ binding: CaptureBinding) { state.withLock { $0.bindingAfterAttach = binding } }
  func holdRuns() { state.withLock { $0.holdingRuns = true } }

  func releaseRuns() {
    let held = state.withLock { state in
      state.holdingRuns = false
      defer { state.heldRuns = [] }
      return state.heldRuns
    }
    for continuation in held { continuation.resume() }
  }

  func waitForHeldRun() async {
    while state.withLock({ $0.heldRuns.isEmpty }) { await Task.yield() }
  }

  var operations: ChatLinkOperations {
    ChatLinkOperations(
      store: "/tmp/store",
      environment: {
        if let error = self.state.withLock({ $0.environmentError }) { throw error }
        var variables = AgentFake.environment.variables
        variables["CLAUDE_CONFIG_DIR"] = "/fake/claude-config"
        variables["CODEX_THREAD_ID"] = "codex-thread"
        variables["CONDUCTOR_SESSION_ID"] = "conductor-session"
        variables["CLAUDE_CODE_SESSION_ID"] = "the-app-itself"
        return AgentEnvironment(
          claudePath: AgentFake.environment.claudePath, variables: variables,
          configDirectory: AgentFake.environment.configDirectory)
      },
      captures: {
        self.state.withLock { state in
          state.calls.append(.captures)
          return [state.older, state.capture].compactMap(\.self)
        }
      },
      run: { arguments, environment in
        self.state.withLock { state in
          state.calls.append(.run(arguments))
          if arguments.first == "attach" { state.environments.append(environment) }
        }
        await withCheckedContinuation { continuation in
          let isHeld = self.state.withLock { state in
            if state.holdingRuns { state.heldRuns.append(continuation) }
            return state.holdingRuns
          }
          if !isHeld { continuation.resume() }
        }
        return self.state.withLock { state in
          let result = state.results[arguments[0]] ?? (0, "")
          if arguments.first == "attach", result.status == 0, let binding = state.bindingAfterAttach {
            state.capture?.binding = binding
          }
          if arguments.first == "unlink", result.status == 0 { state.capture?.binding?.state = .unlinked }
          return result
        }
      }
    )
  }
}
