import Dependencies
import Foundation
import Observation
import SlipstreamCore

struct Evidence: Equatable, Sendable {
  let source: String
  let text: String

  init(source: String, text: String) {
    self.source = Self.redacted(source)
    self.text = Self.redacted(text)
  }

  private static func redacted(_ text: String) -> String {
    redactions.reduce(text) { text, redaction in
      redaction.pattern.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: redaction.template)
    }
  }

  private static let redactions: [(pattern: NSRegularExpression, template: String)] = [
    (try! NSRegularExpression(pattern: #"("token"\s*:\s*)"(?:[^"\\]|\\.)*""#), #"$1"<redacted>""#),
    (
      try! NSRegularExpression(
        pattern: #"(token["']?\s*[:=]?\s*["']?|Bearer\s+)[A-Za-z0-9_\-]{32,}"#, options: .caseInsensitive),
      "$1<redacted>"
    ),
  ]
}

enum RecorderState: Equatable {
  case starting(RuntimeIdentity)
  case running
  case restarting(from: String, to: RuntimeIdentity)
  case updateDidntFinish(running: DaemonBuild, bundled: RuntimeIdentity, Evidence)
  case anotherRecorder(pid: Int32, Evidence)
  case wontStart(RuntimeIdentity?, Evidence)
  case migrationIncomplete(Evidence)
  case external
}

@MainActor
@Observable
final class RecorderModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.continuousClock) var clock
  @ObservationIgnored @Dependency(\.daemon) var daemon
  @ObservationIgnored @Dependency(\.pasteboard) var pasteboard
  @ObservationIgnored @Dependency(\.recorderService) var service
  @ObservationIgnored @Dependency(\.runtimeInstall) var runtimeInstall

  // MARK: - Initialization

  #if DEBUG
    init(
      usesExternalDaemon: Bool = ProcessInfo.processInfo.environment["SLIPSTREAM_EXTERNAL_DAEMON"] == "1"
    ) {
      self.usesExternalDaemon = usesExternalDaemon
      super.init()
    }
  #else
    override init() {
      super.init()
    }
  #endif

  // MARK: - Properties

  private(set) var state = RecorderState.running
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
    if case .migrationIncomplete = state {
      await own { await self.migrate($0) }
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

  func copyTapped() {
    guard let evidence else { return }
    pasteboard.copy(evidence.source + "\n\n" + evidence.text)
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

  private var evidence: Evidence? {
    switch state {
    case let .updateDidntFinish(_, _, evidence), let .anotherRecorder(_, evidence), let .wontStart(_, evidence),
      let .migrationIncomplete(evidence):
      evidence
    case .starting, .running, .restarting, .external:
      nil
    }
  }

  private func own(_ operation: @escaping @MainActor (Int) async -> Void) async {
    work?.cancel()
    generation += 1
    let mine = generation
    let task = Task { await operation(mine) }
    work = task
    await task.value
  }

  private func isCurrent(_ mine: Int) -> Bool {
    mine == generation && !Task.isCancelled
  }

  private func publish(_ state: RecorderState, _ mine: Int) {
    guard isCurrent(mine) else { return }
    replaceTarget = nil
    self.state = state
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
      publish(.wontStart(nil, Evidence(source: "Slipstream.app's bundled recorder", text: "\(error)")), mine)
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
        publish(.updateDidntFinish(running: running, bundled: bundled, Evidence(source: source, text: text)), mine)
      } else {
        publish(.wontStart(bundled, Evidence(source: source, text: "\(error)")), mine)
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
      publish(.wontStart(bundled, Evidence(source: Self.probeSource, text: "\(error)")), mine)
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
      return
    }
    guard let lockPID = probe.lockPID, lockPID == probe.job?.pid else {
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
      publish(.wontStart(bundled, Evidence(source: Self.activateSource, text: "\(error)")), mine)
      return
    }
    guard isCurrent(mine) else { return }
    if probe.job?.pid != nil {
      await poll(bundled, prepared, logOffset: service.logSize(), migrate: false, mine)
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
      publish(.updateDidntFinish(running: running, bundled: bundled, evidence), mine)
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
    publish(.anotherRecorder(pid: pid, Evidence(source: Self.probeSource, text: lines.joined(separator: "\n"))), mine)
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
      publish(.wontStart(bundled, Evidence(source: "kill -TERM \(pid)", text: "\(error)")), mine)
      return
    }
    guard await waitUntilGone(pid, mine) else { return }
    await install(bundled, prepared, mine)
  }

  private func waitUntilGone(_ pid: Int32, _ mine: Int) async -> Bool {
    while true {
      do {
        try await clock.sleep(for: Self.pollInterval)
      } catch {
        return false
      }
      guard isCurrent(mine) else { return false }
      if await isGone(pid) { return isCurrent(mine) }
    }
  }

  private func isGone(_ pid: Int32) async -> Bool {
    do {
      guard try await service.daemonBuild(store) == nil else { return false }
      guard service.ownerLockPID(store) != pid else { return false }
      return try await service.job()?.pid == nil
    } catch {
      return false
    }
  }

  private func install(_ bundled: RuntimeIdentity, _ prepared: PreparedRuntime, _ mine: Int) async {
    let logOffset = service.logSize()
    let run: ShimRun
    do {
      run = try await service.runShim(["service", "install", "--store", daemon.storeID])
    } catch {
      publish(.wontStart(bundled, Evidence(source: "slipstream service install", text: "\(error)")), mine)
      return
    }
    guard isCurrent(mine) else { return }
    guard run.exitCode == 0 else {
      let evidence = Evidence(source: "slipstream service install · exit \(run.exitCode)", text: Self.transcript(run))
      publish(.wontStart(bundled, evidence), mine)
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
      if let running = try? await service.daemonBuild(store) {
        guard isCurrent(mine) else { return }
        guard running == DaemonBuild(version: bundled.version, build: bundled.build) else {
          await evaluate(bundled, prepared, mine)
          return
        }
        publish(.running, mine)
        if migrate { await self.migrate(mine) }
        return
      }
      guard isCurrent(mine) else { return }
      if let job = try? await service.job(), job.pid == nil, let lastExit = job.lastExit {
        guard isCurrent(mine) else { return }
        let log: String
        do {
          log = try service.logSince(logOffset)
        } catch {
          log = "couldn't read \(RecorderServiceClient.logFile.path): \(error)"
        }
        let evidence = Evidence(
          source: "daemon.log since the app started the recorder · last exit code = \(lastExit)",
          text: "last exit code = \(lastExit)\n\n\(log)")
        publish(.wontStart(bundled, evidence), mine)
        return
      }
    }
  }

  private func migrate(_ mine: Int) async {
    var sources: [String] = []
    var sections: [String] = []
    let problems = await runtimeInstall.linkCommands()
    guard isCurrent(mine) else { return }
    if !problems.isEmpty {
      sources.append("~/.local/bin links")
      sections.append(problems.map { "link  \($0.path)\n      \($0.message)" }.joined(separator: "\n"))
    }
    do {
      let run = try await service.runShim(["adopt-app", "--store", daemon.storeID])
      if run.exitCode != 0 {
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
      publish(.migrationIncomplete(evidence), mine)
    }
  }

  private func probe() async throws -> Probe {
    let running = try await service.daemonBuild(store)
    let lockPID = service.ownerLockPID(store)
    let job = try await service.job()
    return Probe(running: running, lockPID: lockPID, job: job)
  }

  private func runningLine(_ running: DaemonBuild, _ probe: Probe) -> String {
    let pid = (probe.job?.pid ?? probe.lockPID).map { "  pid \($0)" } ?? ""
    let build = running.build.map(Self.short) ?? "—"
    return "running\(pid)  daemon_version=\(running.version)  daemon_build=\(build)  (\(Self.label))"
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
