import Dependencies
import Foundation
import IssueReporting
import Sharing
import SlipstreamCore

@MainActor
@Observable
final class TerminalTabModel: ViewModel, Identifiable {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.continuousClock) var clock
  @ObservationIgnored @Dependency(\.terminalHistory) var history
  @ObservationIgnored @Dependency(\.terminalRuntime) var runtime

  // MARK: - Shared State

  @ObservationIgnored @Shared(.terminalState) var state

  // MARK: - Initialization

  init(id: TerminalTabRecord.ID) {
    self.id = id
    surface = TerminalSurface()
    super.init()
    // Input before launch (typing, or the terminal answering queries during replay) is dropped.
    surface.onInput = { [weak self] bytes in self?.handle?.write(bytes) }
    surface.onResize = { [weak self] size in self?.handle?.resize(size) }
  }

  // MARK: - Properties

  let id: TerminalTabRecord.ID
  let surface: TerminalSurface
  var missingFolderPath: String?
  var isCloseConfirmationVisible = false

  var isBusy: Bool {
    if case .setup(.running) = state.tabs[id: id]?.kind { return true }
    return handle?.isBusy() ?? false
  }

  @ObservationIgnored private var handle: TerminalProcessHandle?
  /// The only consumer of `handle.events`; it drains them for the process's whole life.
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var isStarted = false
  @ObservationIgnored private var isStopped = false
  @ObservationIgnored private var setupRun: SetupRun?

  private struct SetupRun {
    var parser = WorkspacePathStreamParser()
    let managedRoot: String
    let elapsed: () -> Duration
    /// Resumed once: with the first valid workspace folder, or nil when the command ends first.
    var workspaceFolder: CheckedContinuation<String?, Never>?
  }

  // MARK: - Display Text

  var title: String {
    switch state.tabs[id: id]?.kind {
    case .setup: "Setup"
    case .terminal(let number): "Terminal \(number)"
    case nil: ""
    }
  }

  var closeConfirmationText: String { "Closing stops what's running in \(title)." }
  var closeAccessibilityLabel: String { "Close \(title)" }
  let stillRunningText = "Still running"
  let keepText = "Keep"
  let closeText = "Close"
  let folderMissingText = "This folder no longer exists"
  let noShellText = "No shell was started."

  var footerText: String? {
    guard let record = state.tabs[id: id], case .setup(let status) = record.kind else { return nil }
    switch status {
    case .running:
      return record.folder.map { "Setting up \(URL(filePath: $0).lastPathComponent)…" } ?? "Setting up…"
    case .finished(let seconds):
      return "Setup finished · \(seconds)s"
    case .failed(let exitStatus?) where record.folder != nil:
      return "Setup failed — exit \(exitStatus). The workspace was created."
    case .failed:
      return "Setup failed — no workspace was created. Close this tab to dismiss."
    case .interrupted:
      return "Setup was interrupted"
    }
  }

  static let restoredText = "Restored — earlier processes ended"

  // MARK: - View Helpers

  var statusIcon: TerminalTabStatusIcon? {
    switch state.tabs[id: id]?.kind {
    case .setup(.running): .running
    case .setup(.finished): .finished
    case .setup(.failed), .setup(.interrupted): .failed
    case .terminal, nil: nil
    }
  }

  // MARK: - User Actions

  /// Replays the saved output, then starts a login shell in the folder. A Setup tab only replays.
  func start() async {
    guard !isStarted, let record = state.tabs[id: id] else { return }
    isStarted = true
    if case .terminal = record.kind, let folder = record.folder, !runtime.folderExists(folder) {
      missingFolderPath = folder
      return
    }
    await replay()
    guard !isStopped, case .terminal = record.kind, let folder = record.folder else { return }
    await launchShell(in: folder)
  }

  /// Runs `slipstream workspace create` in this Setup tab. Returns the workspace folder once the
  /// first valid `workspace_path:` line arrives, or nil if the command ends (or can't start)
  /// without one. The command keeps running after this returns.
  func runSetup(repository: URL, store: String, managedRoot: URL) async -> String? {
    guard !isStarted else { return nil }
    isStarted = true
    do {
      let environment = try await runtime.environment()
      guard !isStopped else { return nil }
      guard let slipstream = environment.slipstream else {
        await setupCouldNotStart(WorkspaceClient.slipstreamNotFoundText)
        return nil
      }
      let handle = try runtime.launch(
        TerminalLaunch(
          executable: slipstream, arguments: ["workspace", "create", repository.path, "--store", store],
          environment: environment.variables, directory: repository.path, size: surface.size))
      self.handle = handle
      let clock: any Clock<Duration> = clock
      setupRun = SetupRun(
        managedRoot: ChangeStreamPageModel.normalizedFolder(managedRoot.path), elapsed: Self.stopwatch(clock))
      return await withCheckedContinuation { continuation in
        setupRun?.workspaceFolder = continuation
        follow(handle)
      }
    } catch {
      guard !isStopped else { return nil }
      await setupCouldNotStart((error as? TerminalLaunchError)?.text ?? error.localizedDescription)
      return nil
    }
  }

  /// Ends the process within `TerminalProcess.hangupGrace`, saves the output it was still
  /// sending, and flushes the history.
  func stop() async {
    isStopped = true
    isCloseConfirmationVisible = false
    await handle?.stop()
    await events?.value
    events = nil
    handle = nil
    await history.flush(id)
  }

  /// Returns true when the tab can close now; otherwise shows the confirmation.
  func closeRequested() -> Bool {
    guard isBusy else { return true }
    isCloseConfirmationVisible = true
    return false
  }

  func keepTapped() {
    isCloseConfirmationVisible = false
  }

  // MARK: - Private Helpers

  private func replay() async {
    let saved = await history.read(id)
    guard !isStopped, !saved.isEmpty else { return }
    surface.feed(saved)
    // Saved too, so a full-screen program left open can't hide this session's output next time.
    write(String(decoding: TerminalSurface.replayReset, as: UTF8.self) + divider(columns: surface.size.columns))
  }

  private func launchShell(in folder: String) async {
    do {
      let environment = try await runtime.environment()
      guard !isStopped else { return }
      var variables = environment.variables
      variables["PWD"] = folder
      let handle = try runtime.launch(
        TerminalLaunch(
          executable: environment.shell, arguments: ["-l"], environment: variables, directory: folder,
          size: surface.size))
      self.handle = handle
      follow(handle)
    } catch {
      guard !isStopped else { return }
      write(note: (error as? TerminalLaunchError)?.text ?? error.localizedDescription)
    }
  }

  private func follow(_ handle: TerminalProcessHandle) {
    events = Task { [weak self] in
      for await event in handle.events { await self?.received(event) }
    }
  }

  private func received(_ event: TerminalEvent) async {
    switch event {
    case .output(let bytes):
      history.append(id, bytes)
      surface.feed(bytes)
      if let paths = setupRun?.parser.consume(bytes) {
        for path in paths { await setupPrinted(path: path) }
      }
    case .finished(let exit):
      handle = nil
      isCloseConfirmationVisible = false
      if setupRun != nil {
        await setupFinished(exit)
      } else if !isStopped {
        write(note: exit.noteText)
      }
    }
  }

  /// Only the first absolute path naming an existing folder two levels below the managed root
  /// counts; a setup script can print its own `workspace_path:` lines.
  private func setupPrinted(path: String) async {
    guard let run = setupRun, run.workspaceFolder != nil else { return }
    let folder = ChangeStreamPageModel.normalizedFolder(path)
    guard path.hasPrefix("/"), ManagedWorkspacePath.contains(folder, root: run.managedRoot),
      runtime.folderExists(folder)
    else { return }
    $state.withLock { $0.moveSetup(id, to: folder) }
    await save()
    resolveSetup(folder)
  }

  /// The status is saved only after the output is flushed. A tab stopped by archive or quit was
  /// already marked interrupted.
  private func setupFinished(_ exit: TerminalExit) async {
    defer { resolveSetup(nil) }
    guard !isStopped, let run = setupRun else { return }
    await history.flush(id)
    let status: SetupStatus =
      switch exit {
      case .exited(0): .finished(seconds: Int(run.elapsed().components.seconds))
      case .exited(let code): .failed(exitStatus: code)
      case .signalled(let signal): .failed(exitStatus: 128 + signal)
      }
    $state.withLock { $0.tabs[id: id]?.kind = .setup(status) }
    await save()
  }

  private func setupCouldNotStart(_ reason: String) async {
    write(note: reason)
    await history.flush(id)
    $state.withLock { $0.tabs[id: id]?.kind = .setup(.failed(exitStatus: nil)) }
    await save()
  }

  private func resolveSetup(_ folder: String?) {
    setupRun?.workspaceFolder?.resume(returning: folder)
    setupRun?.workspaceFolder = nil
  }

  private static func stopwatch(_ clock: some Clock<Duration>) -> () -> Duration {
    let start = clock.now
    return { start.duration(to: clock.now) }
  }

  private func save() async {
    await withErrorReporting { try await $state.save() }
  }

  /// Appends to the history as well as the screen, so the text replays later.
  private func write(_ text: String) {
    let bytes = Array(text.utf8)
    history.append(id, bytes)
    surface.feed(bytes)
  }

  private func write(note: String) {
    write("\r\n\(note)\r\n")
  }

  private func divider(columns: Int) -> String {
    let label = " \(Self.restoredText) "
    let rule = max(columns - label.count, 0)
    let left = String(repeating: "─", count: rule / 2)
    let right = String(repeating: "─", count: rule - rule / 2)
    let tokens = DesignTokens.TerminalPane.self
    return
      "\(tokens.dividerRuleColor)\(left)\(tokens.dividerLabelColor)\(label)\(tokens.dividerRuleColor)\(right)\u{1b}[0m\r\n"
  }
}
