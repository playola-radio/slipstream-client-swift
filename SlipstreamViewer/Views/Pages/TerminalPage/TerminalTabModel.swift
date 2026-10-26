import Dependencies
import Foundation
import Sharing
import SlipstreamCore

@MainActor
@Observable
final class TerminalTabModel: ViewModel, Identifiable {
  // MARK: - Dependencies

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
  var isFolderMissing: Bool { missingFolderPath != nil }

  var isBusy: Bool {
    if case .setup(.running) = state.tabs[id: id]?.kind { return true }
    return handle?.isBusy() ?? false
  }

  @ObservationIgnored private var handle: TerminalProcessHandle?
  /// The only consumer of `handle.events`; it drains them for the process's whole life.
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var isStarted = false
  @ObservationIgnored private var isStopped = false

  // MARK: - Display Text

  var title: String {
    switch state.tabs[id: id]?.kind {
    case .setup: "Setup"
    case .terminal(let number): "Terminal \(number)"
    case nil: ""
    }
  }

  var closeConfirmationText: String { "Closing stops what's running in \(title)." }

  static let restoredText = "Restored — earlier processes ended"

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

  /// Ends the process within `TerminalProcess.hangupGrace` and flushes the history.
  func stop() async {
    isStopped = true
    isCloseConfirmationVisible = false
    await handle?.stop()
    events?.cancel()
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
    surface.feed(saved + TerminalSurface.replayReset)
    write(divider(columns: surface.size.columns))
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
      events = Task { [weak self] in
        for await event in handle.events { self?.received(event) }
      }
    } catch {
      write(note: (error as? TerminalLaunchError)?.text ?? error.localizedDescription)
    }
  }

  private func received(_ event: TerminalEvent) {
    guard !isStopped else { return }
    switch event {
    case .output(let bytes):
      history.append(id, bytes)
      surface.feed(bytes)
    case .finished(let exit):
      handle = nil
      isCloseConfirmationVisible = false
      write(note: exit.noteText)
    }
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
