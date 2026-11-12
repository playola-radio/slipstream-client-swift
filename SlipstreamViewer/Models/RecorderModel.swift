import Dependencies
import Foundation
import Observation
import SlipstreamCore

struct Evidence: Equatable, Sendable {
  let source: String
  let text: String

  init(source: String, text: String) {
    self.source = Redaction.redacted(source)
    self.text = Redaction.redacted(text)
  }
}

enum RecorderState: Equatable {
  case starting(RuntimeIdentity)
  case running
  case restarting(from: String, to: RuntimeIdentity)
  case updateDidntFinish(running: DaemonBuild, bundled: RuntimeIdentity, UpdateFailure, Evidence)
  case anotherRecorder(pid: Int32, running: DaemonBuild, bundled: RuntimeIdentity, Evidence)
  case wontStart(RuntimeIdentity?, StartFailure, Evidence)
  case migrationIncomplete(RuntimeIdentity, MigrationFailure, Evidence)
  case external
}

enum UpdateFailure: Equatable {
  case mismatch(String)
  case copy
  case switchCurrent
}

enum StartFailure: Equatable {
  case unreadableBundle
  case copy
  case probe
  case switchCurrent
  case stop(pid: Int32)
  case serviceInstall(exitCode: Int32?)
  case exited(code: String)
}

struct MigrationFailure: Equatable {
  var links: [String]
  var adoptFailed: Bool
}

@MainActor
@Observable
final class RecorderModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.continuousClock) var clock
  @ObservationIgnored @Dependency(\.daemon) var daemon
  @ObservationIgnored @Dependency(\.recorderService) var service
  @ObservationIgnored @Dependency(\.runtimeInstall) var runtimeInstall
  @ObservationIgnored @Dependency(\.appLog) var appLog

  // MARK: - Initialization

  #if DEBUG
    init(
      state: RecorderState = .running,
      usesExternalDaemon: Bool = ProcessInfo.processInfo.environment["SLIPSTREAM_EXTERNAL_DAEMON"] == "1"
    ) {
      self.state = state
      self.usesExternalDaemon = usesExternalDaemon
      super.init()
    }
  #else
    init(state: RecorderState = .running) {
      self.state = state
      super.init()
    }
  #endif

  // MARK: - Properties

  private(set) var state: RecorderState
  private var replaceTarget: ReplaceTarget?
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  #if DEBUG
    private let usesExternalDaemon: Bool
  #endif

  // MARK: - View Helpers

  var replaceIsAvailable: Bool { replaceTarget != nil }

  // MARK: - User Actions

  func appLaunched() async {
    await own { await self.launch($0) }
  }

  func tryAgainTapped() async {
    if case let .migrationIncomplete(bundled, _, _) = state {
      await own { await self.migrate(bundled, $0) }
    } else {
      await own { await self.launch($0) }
    }
  }

  func replaceItTapped() async {
    guard let target = replaceTarget else { return }
    await own { await self.replace(target, $0) }
  }

  func openLogTapped() {
    service.openLog()
  }

  func quitConfirmed() {
    work?.cancel()
    generation += 1
  }

  // MARK: - Private Helpers

  private struct ReplaceTarget {
    let pid: Int32
    let description: String
    let running: DaemonBuild
    let bundled: RuntimeIdentity
    let prepared: PreparedRuntime
  }

  private struct Probe {
    let running: DaemonBuild?
    let lockPID: Int32?
    let job: LaunchdJob?
  }

  private var store: URL { URL(fileURLWithPath: daemon.storeID) }

  private func own(_ operation: @escaping @MainActor (Int) async -> Void) async {
    let previous = work
    previous?.cancel()
    generation += 1
    let mine = generation
    let task = Task {
      await previous?.value
      guard self.isCurrent(mine) else { return }
      await operation(mine)
    }
    work = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func isCurrent(_ mine: Int) -> Bool {
    mine == generation && !Task.isCancelled
  }

  private func publish(_ state: RecorderState, _ mine: Int) {
    guard isCurrent(mine) else { return }
    replaceTarget = nil
    if state != self.state { log(state) }
    self.state = state
  }

  private func log(_ state: RecorderState) {
    switch state {
    case .starting: appLog.info("recorder", "starting")
    case .running: appLog.info("recorder", "running")
    case .restarting: appLog.info("recorder", "restarting")
    case .external: appLog.info("recorder", "external")
    case .updateDidntFinish(_, _, let failure, let evidence):
      logFailure("updateDidntFinish: \(failure)", evidence)
    case .anotherRecorder(let pid, _, _, let evidence):
      logFailure("anotherRecorder: pid \(pid)", evidence)
    case .wontStart(_, let failure, let evidence):
      logFailure("wontStart: \(failure)", evidence)
    case .migrationIncomplete(_, let failure, let evidence):
      logFailure("migrationIncomplete: \(failure)", evidence)
    }
  }

  private func logFailure(_ summary: String, _ evidence: Evidence) {
    appLog.error("recorder", "\(summary)\n\(evidence.source)\n\(evidence.text)")
  }

  private func launch(_ mine: Int) async {
    #if DEBUG
      if usesExternalDaemon {
        publish(.external, mine)
        return
      }
    #endif
    let bundled: RuntimeIdentity
    do {
      bundled = try runtimeInstall.bundledIdentity()
    } catch {
      publish(
        .wontStart(nil, .unreadableBundle, Evidence(source: "Slipstream.app's bundled recorder", text: "\(error)")),
        mine)
      return
    }
    publish(.starting(bundled), mine)
    let prepared: PreparedRuntime
    do {
      prepared = try await runtimeInstall.prepare()
    } catch {
      let probe = try? await self.probe()
      let source = "prepare runtime/ from Slipstream.app"
      if let probe, let running = probe.running {
        let text = "\(error)\nruntime/current unchanged\n\(runningLine(running, probe))"
        publish(
          .updateDidntFinish(
            running: running, bundled: bundled, Self.updateFailure(error), Evidence(source: source, text: text)),
          mine)
      } else {
        publish(.wontStart(bundled, .copy, Evidence(source: source, text: "\(error)")), mine)
      }
      return
    }
    guard isCurrent(mine) else { return }
    await evaluate(bundled, prepared, mine)
  }

  private func evaluate(_ bundled: RuntimeIdentity, _ prepared: PreparedRuntime, _ mine: Int) async {
    let probe: Probe
    do {
      probe = try await self.probe()
    } catch {
      publishProbeFailure(bundled, error, mine)
      return
    }
    guard isCurrent(mine) else { return }
    guard let running = probe.running else {
      await startStopped(bundled, prepared, probe, mine)
      return
    }
    if running == DaemonBuild(version: bundled.version, build: bundled.build) {
      guard await activateKeepingRunning(running, probe, bundled, prepared, mine) != nil else { return }
      publish(.running, mine)
      await migrate(bundled, mine)
      return
    }
    guard let lockPID = probe.lockPID, lockPID == probe.job?.pid, !running.isNewer(than: bundled) else {
      await reportAnotherRecorder(running, probe, bundled, prepared, newer: nil, mine)
      return
    }
    switch await activateKeepingRunning(running, probe, bundled, prepared, mine) {
    case nil:
      return
    case let .newerActive(current):
      await reportAnotherRecorder(running, probe, bundled, prepared, newer: current, mine)
    case .activated:
      await restart(lockPID, from: running.version, bundled, prepared, mine)
    }
  }

  private func startStopped(
    _ bundled: RuntimeIdentity, _ prepared: PreparedRuntime, _ probe: Probe, _ mine: Int
  ) async {
    do {
      _ = try await runtimeInstall.activate(prepared)
    } catch {
      publish(.wontStart(bundled, .switchCurrent, Evidence(source: Self.activateSource, text: "\(error)")), mine)
      return
    }
    guard isCurrent(mine) else { return }
    if probe.job?.pid != nil {
      await poll(bundled, prepared, logOffset: service.logSize(), migrate: true, mine)
    } else {
      await install(bundled, prepared, mine)
    }
  }

  private func activateKeepingRunning(
    _ running: DaemonBuild, _ probe: Probe, _ bundled: RuntimeIdentity, _ prepared: PreparedRuntime, _ mine: Int
  ) async -> Activation? {
    do {
      let activation = try await runtimeInstall.activate(prepared)
      return isCurrent(mine) ? activation : nil
    } catch {
      let evidence = Evidence(source: Self.activateSource, text: "\(error)\n\(runningLine(running, probe))")
      publish(.updateDidntFinish(running: running, bundled: bundled, .switchCurrent, evidence), mine)
      return nil
    }
  }

  private func reportAnotherRecorder(
    _ running: DaemonBuild, _ probe: Probe, _ bundled: RuntimeIdentity, _ prepared: PreparedRuntime,
    newer current: RuntimeIdentity?, _ mine: Int
  ) async {
    let pid = probe.lockPID ?? probe.job?.pid ?? 0
    let description = pid > 0 ? await service.processDescription(pid) : nil
    guard isCurrent(mine) else { return }
    var lines = [
      "status       daemon_version=\(running.version)  daemon_build=\(running.build.map(Self.short) ?? "—")",
      "owner.lock   \(probe.lockPID.map { "pid \($0)" } ?? "none")",
      "launchd      \(Self.label) — \(Self.jobLine(probe.job))",
    ]
    if pid > 0 {
      lines.append("pid \(pid)    \(description ?? "not running")")
    }
    if let current {
      lines.append(
        "runtime/current → \(current.version) (build \(Self.short(current.build)), app build \(current.appBuild)), "
          + "newer than this app's \(bundled.version) (app build \(bundled.appBuild))")
    }
    let evidence = Evidence(source: Self.probeSource, text: lines.joined(separator: "\n"))
    publish(.anotherRecorder(pid: pid, running: running, bundled: bundled, evidence), mine)
    if current == nil, pid > 0, let description, !running.isNewer(than: bundled) {
      replaceTarget = ReplaceTarget(
        pid: pid, description: description, running: running, bundled: bundled, prepared: prepared)
    }
  }

  private func replace(_ target: ReplaceTarget, _ mine: Int) async {
    let lockPID = service.ownerLockPID(store)
    let description = await service.processDescription(target.pid)
    guard isCurrent(mine) else { return }
    guard lockPID == target.pid, description == target.description else {
      await evaluate(target.bundled, target.prepared, mine)
      return
    }
    let probe = Probe(running: target.running, lockPID: lockPID, job: nil)
    switch await activateKeepingRunning(target.running, probe, target.bundled, target.prepared, mine) {
    case nil:
      return
    case let .newerActive(current):
      await reportAnotherRecorder(target.running, probe, target.bundled, target.prepared, newer: current, mine)
    case .activated:
      await restart(target.pid, from: target.running.version, target.bundled, target.prepared, mine)
    }
  }

  private func restart(
    _ pid: Int32, from version: String, _ bundled: RuntimeIdentity, _ prepared: PreparedRuntime, _ mine: Int
  ) async {
    publish(.restarting(from: version, to: bundled), mine)
    do {
      try service.terminate(pid)
    } catch {
      publish(.wontStart(bundled, .stop(pid: pid), Evidence(source: "kill -TERM \(pid)", text: "\(error)")), mine)
      return
    }
    guard await waitUntilGone(pid, bundled, mine) else { return }
    await install(bundled, prepared, mine)
  }

  private func waitUntilGone(_ pid: Int32, _ bundled: RuntimeIdentity, _ mine: Int) async -> Bool {
    while true {
      do {
        try await clock.sleep(for: Self.pollInterval)
      } catch {
        return false
      }
      guard isCurrent(mine) else { return false }
      do {
        if try await isGone(pid) { return isCurrent(mine) }
      } catch {
        if isOutcomeUnknown(error) { continue }
        publishProbeFailure(bundled, error, mine)
        return false
      }
    }
  }

  private func isGone(_ pid: Int32) async throws -> Bool {
    guard try await service.daemonBuild(store) == nil else { return false }
    guard service.ownerLockPID(store) != pid else { return false }
    return try await service.job()?.pid == nil
  }

  private func install(_ bundled: RuntimeIdentity, _ prepared: PreparedRuntime, _ mine: Int) async {
    let environment = await service.shimEnvironment()
    while true {
      let probe: Probe
      do {
        probe = try await self.probe()
      } catch {
        if isOutcomeUnknown(error) {
          do {
            try await clock.sleep(for: Self.pollInterval)
          } catch {
            return
          }
          continue
        }
        publishProbeFailure(bundled, error, mine)
        return
      }
      guard isCurrent(mine) else { return }
      if probe.running != nil || probe.job?.pid != nil {
        await evaluate(bundled, prepared, mine)
        return
      }
      guard let lockPID = probe.lockPID, await service.processDescription(lockPID) != nil else { break }
      do {
        try await clock.sleep(for: Self.pollInterval)
      } catch {
        return
      }
      guard isCurrent(mine) else { return }
    }
    let logOffset = service.logSize()
    let run: ShimRun
    do {
      run = try await service.runShim(["service", "install", "--store", daemon.storeID], environment)
    } catch {
      let evidence = Evidence(source: "slipstream service install", text: "\(error)")
      publish(.wontStart(bundled, .serviceInstall(exitCode: nil), evidence), mine)
      return
    }
    guard isCurrent(mine) else { return }
    guard run.exitCode == 0 else {
      let evidence = Evidence(source: "slipstream service install · exit \(run.exitCode)", text: Self.transcript(run))
      publish(.wontStart(bundled, .serviceInstall(exitCode: run.exitCode), evidence), mine)
      return
    }
    if case .restarting = state {} else {
      publish(.starting(bundled), mine)
    }
    await poll(bundled, prepared, logOffset: logOffset, migrate: true, mine)
  }

  private func poll(
    _ bundled: RuntimeIdentity, _ prepared: PreparedRuntime, logOffset: UInt64, migrate: Bool, _ mine: Int
  ) async {
    while true {
      do {
        try await clock.sleep(for: Self.pollInterval)
      } catch {
        return
      }
      guard isCurrent(mine) else { return }
      let running: DaemonBuild?
      do {
        running = try await service.daemonBuild(store)
      } catch {
        if isOutcomeUnknown(error) { continue }
        publishProbeFailure(bundled, error, mine)
        return
      }
      guard isCurrent(mine) else { return }
      if let running {
        guard running == DaemonBuild(version: bundled.version, build: bundled.build) else {
          await evaluate(bundled, prepared, mine)
          return
        }
        publish(.running, mine)
        if migrate { await self.migrate(bundled, mine) }
        return
      }
      let job: LaunchdJob?
      do {
        job = try await service.job()
      } catch {
        publishProbeFailure(bundled, error, mine)
        return
      }
      guard isCurrent(mine) else { return }
      if let job, job.pid == nil, let lastExit = job.lastExit {
        let log: String
        do {
          log = try service.logSince(logOffset)
        } catch {
          log = "couldn't read \(RecorderServiceClient.logFile.path): \(error)"
        }
        let evidence = Evidence(
          source: "daemon.log since the app started the recorder · last exit code = \(lastExit)",
          text: "last exit code = \(lastExit)\n\n\(log)")
        publish(.wontStart(bundled, .exited(code: lastExit), evidence), mine)
        return
      }
    }
  }

  private func migrate(_ bundled: RuntimeIdentity, _ mine: Int) async {
    var sources: [String] = []
    var sections: [String] = []
    let problems = await runtimeInstall.linkCommands()
    guard isCurrent(mine) else { return }
    if !problems.isEmpty {
      sources.append("~/.local/bin links")
      sections.append(problems.map { "link  \($0.path)\n      \($0.message)" }.joined(separator: "\n"))
    }
    let environment = await service.shimEnvironment()
    guard isCurrent(mine) else { return }
    var adoptFailed = true
    do {
      let run = try await service.runShim(["adopt-app", "--store", daemon.storeID], environment)
      adoptFailed = run.exitCode != 0
      if adoptFailed {
        sources.append("slipstream adopt-app · exit \(run.exitCode)")
        sections.append(Self.transcript(run))
      }
    } catch {
      sources.append("slipstream adopt-app")
      sections.append("\(error)")
    }
    guard isCurrent(mine) else { return }
    if sections.isEmpty {
      publish(.running, mine)
    } else {
      let evidence = Evidence(
        source: sources.joined(separator: " · "), text: sections.joined(separator: "\n\n"))
      let failure = MigrationFailure(
        links: problems.map { URL(fileURLWithPath: $0.path).lastPathComponent }, adoptFailed: adoptFailed)
      publish(.migrationIncomplete(bundled, failure, evidence), mine)
    }
  }

  private func probe() async throws -> Probe {
    let running = try await service.daemonBuild(store)
    let lockPID = service.ownerLockPID(store)
    let job = try await service.job()
    return Probe(running: running, lockPID: lockPID, job: job)
  }

  private func publishProbeFailure(_ bundled: RuntimeIdentity, _ error: any Error, _ mine: Int) {
    publish(.wontStart(bundled, .probe, Evidence(source: Self.probeSource, text: "\(error)")), mine)
  }

  private func isOutcomeUnknown(_ error: any Error) -> Bool {
    guard let error = error as? QuestionError else { return false }
    return error == .outcomeUnknown
  }

  private func runningLine(_ running: DaemonBuild, _ probe: Probe) -> String {
    let pid = (probe.job?.pid ?? probe.lockPID).map { "  pid \($0)" } ?? ""
    let build = running.build.map(Self.short) ?? "—"
    return "running\(pid)  daemon_version=\(running.version)  daemon_build=\(build)  (\(Self.label))"
  }

  private static func updateFailure(_ error: any Error) -> UpdateFailure {
    guard case let .differs(path, expected, _) = error as? RuntimeInstallError else { return .copy }
    let file = URL(fileURLWithPath: path).lastPathComponent
    return .mismatch(expected.hasPrefix("sha256:") ? "\(file) hash" : file)
  }

  private static func jobLine(_ job: LaunchdJob?) -> String {
    guard let job else { return "not loaded" }
    if let pid = job.pid { return "pid \(pid)" }
    return "not running" + (job.lastExit.map { " (last exit code = \($0))" } ?? "")
  }

  private static func transcript(_ run: ShimRun) -> String {
    let output = run.output.isEmpty || run.output.hasSuffix("\n") ? run.output : run.output + "\n"
    return "$ \(run.command)\n\(output)exit \(run.exitCode)"
  }

  private static func short(_ build: String) -> String {
    String(build.prefix(8))
  }

  private static let label = RecorderServiceClient.label
  private static let pollInterval = Duration.milliseconds(250)
  private static let probeSource = "status · owner.lock · launchctl"
  private static let activateSource = "point runtime/current at the new copy"
}
