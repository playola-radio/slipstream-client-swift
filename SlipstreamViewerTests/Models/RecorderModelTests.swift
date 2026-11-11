import Clocks
import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct RecorderModelTests {
  nonisolated static let bundled = RuntimeIdentity(
    version: "0.3.2", build: "7f3c9a1e-5b0d-4f8e-a1c4-96d2e07b5f13", appBuild: 12)
  nonisolated static let bundledBuild = DaemonBuild(version: bundled.version, build: bundled.build)
  nonisolated static let oldBuild = DaemonBuild(version: "0.3.1", build: "2b81c4d0-9e1f-4a6b-8c3d-5f7e9a1b2c3d")
  nonisolated static let prepared = PreparedRuntime(
    identity: bundled, directory: URL(fileURLWithPath: "/rt/0.3.2-7f3c9a1e"))
  nonisolated static let installCommand = "service install --store test-store"
  nonisolated static let adoptCommand = "adopt-app --store test-store"

  let clock = TestClock()
  let fake: RecorderFake

  init() {
    fake = RecorderFake(clock: clock)
  }

  func makeModel() -> RecorderModel {
    withDependencies {
      $0.continuousClock = clock
      $0.recorderService = fake.service
      $0.runtimeInstall = fake.runtimeInstall
    } operation: {
      RecorderModel()
    }
  }

  func runOwnedOldBuild() {
    fake.running.setValue(Self.oldBuild)
    fake.lockPID.setValue(48213)
    fake.job.setValue(LaunchdJob(pid: 48213, lastExit: nil))
  }

  func runUnmanagedDaemon() {
    fake.running.setValue(DaemonBuild(version: "0.3.0", build: nil))
    fake.lockPID.setValue(30117)
    fake.descriptions.setValue([30117: "Mon Oct 27 09:14:52 2026     node /npm/slipstream/dist/cli.js start"])
  }

  func oldDaemonExits() {
    fake.running.setValue(nil)
    fake.lockPID.setValue(nil)
    fake.job.setValue(LaunchdJob(pid: nil, lastExit: "0"))
  }

  @Test func updateDidntFinishKeepsOldRunning() async {
    runOwnedOldBuild()
    fake.prepareResult.setValue(
      .failure(.differs(path: "app/node_modules/watcher.node", expected: "sha256:9c1e", actual: "sha256:3d77")))
    let model = makeModel()

    await model.appLaunched()

    expectNoDifference(
      model.state,
      .updateDidntFinish(
        running: Self.oldBuild, bundled: Self.bundled, .mismatch("watcher.node hash"),
        Evidence(
          source: "prepare runtime/ from Slipstream.app",
          text: """
            app/node_modules/watcher.node differs from the bundle: expected sha256:9c1e, found sha256:3d77
            runtime/current unchanged
            running  pid 48213  daemon_version=0.3.1  daemon_build=2b81c4d0  (radio.playola.slipstream)
            """)))
    expectNoDifference(fake.events.value, ["prepare"])
  }

  @Test func freshStartInstallsService() async {
    let model = makeModel()

    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    expectNoDifference(model.state, .starting(Self.bundled))
    expectNoDifference(fake.events.value, ["prepare", "activate", Self.installCommand])

    await clock.advance(by: .milliseconds(250))
    await launch.value

    expectNoDifference(model.state, .running)
    expectNoDifference(fake.events.value, ["prepare", "activate", Self.installCommand, "link", Self.adoptCommand])
  }

  @Test func serviceInstallFailureIsWontStart() async {
    fake.shimResults.setValue([
      "service": (1, "slipstream: launchctl could not load radio.playola.slipstream (exit 5): Bootstrap failed: 5\n")
    ])
    let model = makeModel()

    await model.appLaunched()

    expectNoDifference(
      model.state,
      .wontStart(
        Self.bundled, .serviceInstall(exitCode: 1),
        Evidence(
          source: "slipstream service install · exit 1",
          text: """
            $ /rt/bin/slipstream service install --store test-store
            slipstream: launchctl could not load radio.playola.slipstream (exit 5): Bootstrap failed: 5
            exit 1
            """)))
  }

  @Test func sameBuildIsRunningMigrates() async {
    fake.running.setValue(Self.bundledBuild)
    fake.lockPID.setValue(501)
    fake.job.setValue(LaunchdJob(pid: 501, lastExit: nil))
    let model = makeModel()

    await model.appLaunched()

    expectNoDifference(model.state, .running)
    expectNoDifference(fake.events.value, ["prepare", "activate", "link", Self.adoptCommand])
  }

  @Test func unfinishedMigrationIsRetriedOnRelaunch() async {
    fake.running.setValue(Self.bundledBuild)
    fake.lockPID.setValue(501)
    fake.job.setValue(LaunchdJob(pid: 501, lastExit: nil))
    fake.shimResults.setValue(["adopt-app": (1, "failed /w/.claude/settings.local.json: EACCES\n")])
    let model = makeModel()

    await model.appLaunched()

    expectNoDifference(
      model.state,
      .migrationIncomplete(
        Self.bundled,
        MigrationFailure(links: [], adoptFailed: true),
        Evidence(
          source: "slipstream adopt-app · exit 1",
          text: """
            $ /rt/bin/slipstream adopt-app --store test-store
            failed /w/.claude/settings.local.json: EACCES
            exit 1
            """)))
    expectNoDifference(fake.events.value, ["prepare", "activate", "link", Self.adoptCommand])
  }

  @Test func ownedOtherBuildRestarts() async {
    runOwnedOldBuild()
    let model = makeModel()

    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    expectNoDifference(model.state, .restarting(from: "0.3.1", to: Self.bundled))
    expectNoDifference(fake.events.value, ["prepare", "activate", "terminate 48213"])

    oldDaemonExits()
    await clock.advance(by: .milliseconds(250))

    expectNoDifference(model.state, .restarting(from: "0.3.1", to: Self.bundled))
    expectNoDifference(fake.events.value, ["prepare", "activate", "terminate 48213", Self.installCommand])

    await clock.advance(by: .milliseconds(250))
    await launch.value

    expectNoDifference(model.state, .running)
    expectNoDifference(
      fake.events.value,
      ["prepare", "activate", "terminate 48213", Self.installCommand, "link", Self.adoptCommand])
  }

  @Test func serviceInstallWaitsForOwnedDaemonToExit() async {
    runOwnedOldBuild()
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    await clock.advance(by: .milliseconds(250))
    #expect(!fake.events.value.contains(Self.installCommand))

    fake.running.setValue(nil)
    await clock.advance(by: .milliseconds(250))
    #expect(!fake.events.value.contains(Self.installCommand))

    fake.lockPID.setValue(nil)
    await clock.advance(by: .milliseconds(250))
    #expect(!fake.events.value.contains(Self.installCommand))

    fake.job.setValue(LaunchdJob(pid: nil, lastExit: "0"))
    await clock.advance(by: .milliseconds(250))
    #expect(fake.events.value.contains(Self.installCommand))

    await clock.advance(by: .milliseconds(250))
    await launch.value
    expectNoDifference(model.state, .running)
  }

  @Test func serviceInstallWaitsForLiveLockHolder() async {
    fake.lockPID.setValue(30117)
    fake.descriptions.setValue([30117: "Mon Oct 27 09:14:52 2026     node /npm/slipstream/dist/cli.js start"])
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    await clock.advance(by: .milliseconds(250))
    expectNoDifference(model.state, .starting(Self.bundled))
    expectNoDifference(fake.events.value, ["prepare", "activate"])

    fake.lockPID.setValue(nil)
    await clock.advance(by: .milliseconds(250))
    expectNoDifference(fake.events.value, ["prepare", "activate", Self.installCommand])

    await clock.advance(by: .milliseconds(250))
    await launch.value
    expectNoDifference(model.state, .running)
  }

  @Test func daemonThatStartsWhileTheShellLoadsIsNotInstalledOver() async {
    fake.startsWhileEnvironmentLoads.setValue(Self.bundledBuild)
    let model = makeModel()

    await model.appLaunched()

    expectNoDifference(model.state, .running)
    expectNoDifference(fake.events.value, ["prepare", "activate", "activate", "link", Self.adoptCommand])
  }

  @Test func probeFailureWhileStoppingIsWontStart() async {
    runOwnedOldBuild()
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    fake.statusError.setValue(RecorderServiceError(description: "status reply wasn't JSON"))
    await clock.advance(by: .milliseconds(250))
    await launch.value

    expectNoDifference(
      model.state,
      .wontStart(
        Self.bundled, .probe,
        Evidence(source: "status · owner.lock · launchctl", text: "status reply wasn't JSON")))
    #expect(!fake.events.value.contains(Self.installCommand))
  }

  @Test func outcomeUnknownWhileStoppingKeepsWaitingForTheRecorderToExit() async {
    runOwnedOldBuild()
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    fake.statusErrors.setValue([.outcomeUnknown])
    await clock.advance(by: .milliseconds(250))
    expectNoDifference(model.state, .restarting(from: "0.3.1", to: Self.bundled))

    oldDaemonExits()
    await clock.advance(by: .milliseconds(250))
    await clock.advance(by: .milliseconds(250))
    await launch.value

    expectNoDifference(model.state, .running)
  }

  @Test func outcomeUnknownBeforeInstallWaitsWithoutInstalling() async {
    fake.statusErrors.setValue([.outcomeUnknown])
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    expectNoDifference(fake.events.value, ["prepare", "activate"])
    await clock.advance(by: .milliseconds(250))
    expectNoDifference(fake.events.value, ["prepare", "activate", Self.installCommand])

    await clock.advance(by: .milliseconds(250))
    await launch.value
    expectNoDifference(model.state, .running)
  }

  @Test func probeFailureWhileStartingIsWontStart() async {
    fake.startsOnInstall.setValue(nil)
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    fake.statusError.setValue(RecorderServiceError(description: "status reply wasn't JSON"))
    await clock.advance(by: .milliseconds(250))
    await launch.value

    expectNoDifference(
      model.state,
      .wontStart(
        Self.bundled, .probe,
        Evidence(source: "status · owner.lock · launchctl", text: "status reply wasn't JSON")))
  }

  @Test func retryWaitsForTheInstallInFlight() async {
    fake.installTakes.setValue(.seconds(1))
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()
    expectNoDifference(fake.events.value, ["prepare", "activate", Self.installCommand])

    let retry = Task { await model.tryAgainTapped() }
    await Task.megaYield()
    expectNoDifference(fake.events.value, ["prepare", "activate", Self.installCommand])

    await clock.advance(by: .seconds(1))
    await launch.value
    await retry.value

    expectNoDifference(model.state, .running)
    expectNoDifference(
      fake.events.value,
      ["prepare", "activate", Self.installCommand, "prepare", "activate", "link", Self.adoptCommand])
  }

  @Test func quitStopsRecorderWork() async {
    runOwnedOldBuild()
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    model.quitConfirmed()
    oldDaemonExits()
    await clock.advance(by: .milliseconds(500))
    await launch.value

    expectNoDifference(fake.events.value, ["prepare", "activate", "terminate 48213"])
  }

  @Test func cancellingLaunchStopsRecorderWork() async {
    runOwnedOldBuild()
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    launch.cancel()
    oldDaemonExits()
    await clock.advance(by: .milliseconds(500))
    await launch.value

    expectNoDifference(fake.events.value, ["prepare", "activate", "terminate 48213"])
  }

  @Test func flipFailureStopsNothing() async {
    runOwnedOldBuild()
    fake.activation.setValue(
      .failure(.io(step: "point current", path: "/rt/current", errno: 13, message: "Permission denied")))
    let model = makeModel()

    await model.appLaunched()

    expectNoDifference(
      model.state,
      .updateDidntFinish(
        running: Self.oldBuild, bundled: Self.bundled, .switchCurrent,
        Evidence(
          source: "point runtime/current at the new copy",
          text: """
            point current failed at /rt/current: Permission denied (errno 13)
            running  pid 48213  daemon_version=0.3.1  daemon_build=2b81c4d0  (radio.playola.slipstream)
            """)))
    expectNoDifference(fake.events.value, ["prepare", "activate"])
  }

  @Test func unmanagedDaemonIsNeverStopped() async {
    runUnmanagedDaemon()
    let model = makeModel()

    await model.appLaunched()

    expectNoDifference(
      model.state,
      .anotherRecorder(
        pid: 30117, running: DaemonBuild(version: "0.3.0", build: nil),
        Evidence(
          source: "status · owner.lock · launchctl",
          text: """
            status       daemon_version=0.3.0  daemon_build=—
            owner.lock   pid 30117
            launchd      radio.playola.slipstream — not loaded
            pid 30117    Mon Oct 27 09:14:52 2026     node /npm/slipstream/dist/cli.js start
            """)))
    #expect(model.replaceIsAvailable)
    expectNoDifference(fake.events.value, ["prepare"])
  }

  @Test func olderAppDoesNotStopNewerDaemon() async {
    fake.running.setValue(DaemonBuild(version: "0.3.3", build: "9d0e1f2a-0000-0000-0000-000000000000"))
    fake.lockPID.setValue(48213)
    fake.job.setValue(LaunchdJob(pid: 48213, lastExit: nil))
    fake.activation.setValue(
      .success(.newerActive(RuntimeIdentity(version: "0.3.3", build: "9d0e1f2a-0000", appBuild: 14))))
    let model = makeModel()

    await model.appLaunched()

    guard case .anotherRecorder(pid: 48213, _, _) = model.state else {
      Issue.record("Expected another recorder, got \(model.state)")
      return
    }
    #expect(!model.replaceIsAvailable)
    expectNoDifference(fake.events.value, ["prepare"])
  }

  @Test func newerManagedDaemonIsNeverStopped() async {
    fake.running.setValue(DaemonBuild(version: "0.4.0", build: "9d0e1f2a-0000-0000-0000-000000000000"))
    fake.lockPID.setValue(48213)
    fake.job.setValue(LaunchdJob(pid: 48213, lastExit: nil))
    fake.descriptions.setValue([48213: "Mon Oct 27 09:14:52 2026     node /npm/slipstream/dist/cli.js start"])
    let model = makeModel()

    await model.appLaunched()

    guard case .anotherRecorder(pid: 48213, _, _) = model.state else {
      Issue.record("Expected another recorder, got \(model.state)")
      return
    }
    #expect(!model.replaceIsAvailable)
    expectNoDifference(fake.events.value, ["prepare"])
  }

  @Test func sameDaemonVersionOlderAppBuildIsAnotherRecorder() async {
    fake.running.setValue(DaemonBuild(version: "0.3.2", build: "c0ffee00-0000-0000-0000-000000000000"))
    fake.lockPID.setValue(48213)
    fake.job.setValue(LaunchdJob(pid: 48213, lastExit: nil))
    fake.activation.setValue(
      .success(.newerActive(RuntimeIdentity(version: "0.3.2", build: "c0ffee00-0000", appBuild: 13))))
    let model = makeModel()

    await model.appLaunched()

    guard case let .anotherRecorder(pid: 48213, _, evidence) = model.state else {
      Issue.record("Expected another recorder, got \(model.state)")
      return
    }
    #expect(evidence.text.contains("runtime/current → 0.3.2 (build c0ffee00, app build 13)"))
    #expect(!model.replaceIsAvailable)
    expectNoDifference(fake.events.value, ["prepare", "activate"])
  }

  @Test func exitDuringStartIsWontStart() async {
    fake.logSize.setValue(4096)
    fake.startsOnInstall.setValue(nil)
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    fake.job.setValue(LaunchdJob(pid: nil, lastExit: "1"))
    await clock.advance(by: .milliseconds(250))
    await launch.value

    expectNoDifference(
      model.state,
      .wontStart(
        Self.bundled, .exited(code: "1"),
        Evidence(
          source: "daemon.log since the app started the recorder · last exit code = 1",
          text: "last exit code = 1\n\nlog after 4096")))
  }

  @Test func adoptFailureIsMigrationIncomplete() async {
    fake.linkProblems.setValue([
      LinkProblem(path: "/Users/x/.local/bin/slipstream", message: "File exists and isn't a symlink; left alone.")
    ])
    fake.shimResults.setValue(["adopt-app": (1, "failed /w/.claude/settings.local.json: EACCES\n")])
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()

    await clock.advance(by: .milliseconds(250))
    await launch.value

    expectNoDifference(
      model.state,
      .migrationIncomplete(
        Self.bundled, MigrationFailure(links: ["slipstream"], adoptFailed: true),
        Evidence(
          source: "~/.local/bin links · slipstream adopt-app · exit 1",
          text: """
            link  /Users/x/.local/bin/slipstream
                  File exists and isn't a symlink; left alone.

            $ /rt/bin/slipstream adopt-app --store test-store
            failed /w/.claude/settings.local.json: EACCES
            exit 1
            """)))
  }

  @Test func tryAgainFromMigrationIncompleteRerunsOnlyAdopt() async {
    fake.shimResults.setValue(["adopt-app": (1, "claude: command not found\n")])
    let model = makeModel()
    let launch = Task { await model.appLaunched() }
    await Task.megaYield()
    await clock.advance(by: .milliseconds(250))
    await launch.value
    guard case .migrationIncomplete = model.state else {
      Issue.record("Expected migration incomplete, got \(model.state)")
      return
    }
    fake.events.setValue([])
    fake.shimResults.setValue([:])

    await model.tryAgainTapped()

    expectNoDifference(model.state, .running)
    expectNoDifference(fake.events.value, ["link", Self.adoptCommand])
  }

  @Test func replaceItRevalidatesPid() async {
    runUnmanagedDaemon()
    let model = makeModel()
    await model.appLaunched()
    fake.lockPID.setValue(30200)
    fake.descriptions.setValue([30200: "Tue Oct 28 10:00:00 2026     node /npm/slipstream/dist/cli.js start"])

    await model.replaceItTapped()

    guard case .anotherRecorder(pid: 30200, _, _) = model.state else {
      Issue.record("Expected another recorder 30200, got \(model.state)")
      return
    }
    #expect(!fake.events.value.contains { $0.hasPrefix("terminate") })
  }

  @Test func replaceItStopsTheSameProcessThenInstalls() async {
    runUnmanagedDaemon()
    let model = makeModel()
    await model.appLaunched()

    let replace = Task { await model.replaceItTapped() }
    await Task.megaYield()

    expectNoDifference(model.state, .restarting(from: "0.3.0", to: Self.bundled))
    expectNoDifference(fake.events.value, ["prepare", "activate", "terminate 30117"])

    oldDaemonExits()
    await clock.advance(by: .milliseconds(250))
    await clock.advance(by: .milliseconds(250))
    await replace.value

    expectNoDifference(model.state, .running)
    expectNoDifference(
      fake.events.value,
      ["prepare", "activate", "terminate 30117", Self.installCommand, "link", Self.adoptCommand])
  }

  @Test func evidenceRedactsToken() {
    let secret = "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"

    let evidence = Evidence(
      source: "GET /v1/status Authorization: Bearer \(secret)",
      text: """
        {"token": "short-but-secret", "pid": 1}
        SLIPSTREAM_TOKEN=\(secret)
        token: '\(secret)'
        {"error":"descriptor: {\\"token\\":\\"\(secret)\\"}"}
        "{\\\\\\"token\\\\\\":\\\\\\"\(secret)\\\\\\"}"
        """)

    expectNoDifference(
      evidence,
      Evidence(
        source: "GET /v1/status Authorization: Bearer <redacted>",
        text: """
          {"token": "<redacted>", "pid": 1}
          SLIPSTREAM_TOKEN=<redacted>
          token: '<redacted>'
          {"error":"descriptor: {\\"token\\":\\"<redacted>\\"}"}
          "{\\\\\\"token\\\\\\":\\\\\\"<redacted>\\\\\\"}"
          """))
    #expect(!evidence.text.contains(secret) && !evidence.source.contains(secret))
  }

  #if DEBUG
    @Test func externalModeTouchesNothing() async {
      let model = RecorderModel(usesExternalDaemon: true)

      await model.appLaunched()

      expectNoDifference(model.state, .external)
    }
  #endif

  @Test func openLogOpensTheDaemonLog() async {
    let model = makeModel()

    model.openLogTapped()

    expectNoDifference(fake.events.value, ["open log"])
  }
}

final class RecorderFake: Sendable {
  let clock: TestClock<Duration>
  let events = LockIsolated<[String]>([])
  let prepareResult = LockIsolated<Result<PreparedRuntime, RuntimeInstallError>>(
    .success(RecorderModelTests.prepared))
  let activation = LockIsolated<Result<Activation, RuntimeInstallError>>(.success(.activated))
  let linkProblems = LockIsolated<[LinkProblem]>([])
  let running = LockIsolated<DaemonBuild?>(nil)
  let lockPID = LockIsolated<Int32?>(nil)
  let job = LockIsolated<LaunchdJob?>(nil)
  let descriptions = LockIsolated<[Int32: String]>([:])
  let logSize = LockIsolated<UInt64>(0)
  let shimResults = LockIsolated<[String: (Int32, String)]>([:])
  let startsOnInstall = LockIsolated<DaemonBuild?>(RecorderModelTests.bundledBuild)
  let statusError = LockIsolated<RecorderServiceError?>(nil)
  let statusErrors = LockIsolated<[QuestionError]>([])
  let installTakes = LockIsolated<Duration?>(nil)
  let startsWhileEnvironmentLoads = LockIsolated<DaemonBuild?>(nil)

  init(clock: TestClock<Duration>) {
    self.clock = clock
  }

  var runtimeInstall: RuntimeInstallClient {
    RuntimeInstallClient(
      bundledIdentity: { RecorderModelTests.bundled },
      prepare: {
        self.record("prepare")
        return try self.prepareResult.value.get()
      },
      activate: { _ in
        self.record("activate")
        return try self.activation.value.get()
      },
      linkCommands: {
        self.record("link")
        return self.linkProblems.value
      }
    )
  }

  var service: RecorderServiceClient {
    RecorderServiceClient(
      job: { self.job.value },
      terminate: { pid in self.record("terminate \(pid)") },
      ownerLockPID: { _ in self.lockPID.value },
      daemonBuild: { _ in
        if let error = self.statusErrors.withValue({ $0.isEmpty ? nil : $0.removeFirst() }) { throw error }
        if let error = self.statusError.value { throw error }
        return self.running.value
      },
      processDescription: { pid in self.descriptions.value[pid] },
      logSize: { self.logSize.value },
      logSince: { offset in "log after \(offset)" },
      shimEnvironment: {
        if let build = self.startsWhileEnvironmentLoads.value {
          self.running.setValue(build)
          self.lockPID.setValue(501)
          self.job.setValue(LaunchdJob(pid: 501, lastExit: nil))
        }
        return [:]
      },
      runShim: { arguments, _ in
        self.record(arguments.joined(separator: " "))
        let (exitCode, output) = self.shimResults.value[arguments[0]] ?? (0, "")
        if arguments[0] == "service", let duration = self.installTakes.value {
          await Task { try? await self.clock.sleep(for: duration) }.value
        }
        if arguments[0] == "service", exitCode == 0 {
          self.running.setValue(self.startsOnInstall.value)
        }
        return ShimRun(
          command: "/rt/bin/slipstream " + arguments.joined(separator: " "), exitCode: exitCode, output: output)
      },
      openLog: { self.record("open log") }
    )
  }

  private func record(_ event: String) {
    events.withValue { $0.append(event) }
  }
}
