import Dependencies
import Foundation
import IdentifiedCollections
import IssueReporting
import Sharing

@MainActor
@Observable
final class TerminalPageModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.terminalHistory) var history
  @ObservationIgnored @Dependency(\.uuid) var uuid

  // MARK: - Shared State

  @ObservationIgnored @Shared(.terminalState) var state

  // MARK: - Initialization

  override init() {
    super.init()
  }

  // MARK: - Properties

  private(set) var folder: String?
  /// Live tabs, by record id. A tab is created and started the first time its workspace shows.
  private var tabs: IdentifiedArrayOf<TerminalTabModel> = []
  private var listedFolders: Set<String> = []
  /// Folders being archived: their tabs are stopped and none start until restored or forgotten.
  private var stoppedFolders: Set<String> = []
  private var isQuitting = false
  private var isLaunched = false
  private var focusedTabID: TerminalTabRecord.ID?
  private var hoveredTabID: TerminalTabRecord.ID?

  var shownTabs: [TerminalTabModel] {
    state.tabs(shownIn: folder, listed: listedFolders).compactMap { tabs[id: $0.id] }
  }

  var selectedTab: TerminalTabModel? {
    let shown = shownTabs
    let selectedID = folder.flatMap { state.selectedTabIDs[$0] }
    return shown.first { $0.id == selectedID } ?? shown.first
  }

  var hasKeyboardFocus: Bool { focusedTabID != nil }

  // MARK: - Display Text

  let emptyTitle = "Choose a workspace"
  let emptyText = "Its terminals appear here."
  let newTabAccessibilityLabel = "New terminal"
  let hideTerminalsText = "Hide terminals"

  // MARK: - View Helpers

  var isEmptyStateVisible: Bool {
    folder == nil && state.tabs(shownIn: nil, listed: listedFolders).isEmpty
  }

  var showsNewTabButton: Bool { folder != nil }

  func isSelected(_ tab: TerminalTabModel) -> Bool { selectedTab?.id == tab.id }

  func isHovered(_ tab: TerminalTabModel) -> Bool { hoveredTabID == tab.id }

  func showsCloseButton(_ tab: TerminalTabModel) -> Bool { isSelected(tab) || isHovered(tab) }

  func tabStatusIcon(_ tab: TerminalTabModel) -> TerminalTabStatusIcon? {
    switch state.tabs[id: tab.id]?.kind {
    case .setup(.running): .running
    case .setup(.finished): .finished
    case .setup(.failed), .setup(.interrupted): .failed
    case .terminal, nil: nil
    }
  }

  // MARK: - User Actions

  /// Marks every Setup that was running when the app last quit as interrupted. Runs once.
  func launched() async {
    guard !isLaunched else { return }
    isLaunched = true
    $state.withLock { state in
      for record in state.tabs where record.kind == .setup(.running) {
        state.tabs[id: record.id]?.kind = .setup(.interrupted)
      }
    }
    await save()
  }

  func workspaceChanged(folder: String?) async {
    self.folder = folder
    if let folder, !hasTerminalTab(in: folder) {
      await addTerminal(in: folder)
    } else {
      await startShownTabs()
    }
  }

  func workspacesListed(_ folders: Set<String>) {
    listedFolders = folders
  }

  func newTabTapped() async {
    guard let folder else { return }
    await addTerminal(in: folder)
  }

  func tabSelected(_ id: TerminalTabRecord.ID) {
    guard let folder, let tab = shownTabs.first(where: { $0.id == id }) else { return }
    $state.withLock { $0.selectedTabIDs[folder] = id }
    tab.surface.focus()
  }

  /// A busy tab asks first, and is selected so the question shows.
  func closeTabTapped(_ id: TerminalTabRecord.ID) async {
    guard let tab = shownTabs.first(where: { $0.id == id }) else { return }
    guard tab.closeRequested() else {
      tabSelected(id)
      return
    }
    await close(tab)
  }

  func closeConfirmed(_ id: TerminalTabRecord.ID) async {
    guard let tab = tabs[id: id] else { return }
    await close(tab)
  }

  func closeShortcutPressed() async {
    guard let id = selectedTab?.id else { return }
    await closeTabTapped(id)
  }

  func tabHovered(_ id: TerminalTabRecord.ID, isHovering: Bool) {
    if isHovering {
      hoveredTabID = id
    } else if hoveredTabID == id {
      hoveredTabID = nil
    }
  }

  func terminalFocusChanged(_ id: TerminalTabRecord.ID, isFocused: Bool) {
    if isFocused {
      focusedTabID = id
    } else if focusedTabID == id {
      focusedTabID = nil
    }
  }

  /// Stops the folder's tabs before it is archived. Its records and logs are kept until
  /// `forgetTabs(in:)`; `restoreTabs(in:)` starts them again.
  func stopTabs(in folder: String) async {
    stoppedFolders.insert(folder)
    let stopping = tabs(in: folder)
    await withTaskGroup { group in
      for tab in stopping {
        group.addTask { await tab.stop() }
      }
    }
    for tab in stopping { tabs[id: tab.id] = nil }
  }

  /// Lets the folder's tabs start again after a failed archive; showing the folder starts them.
  func restoreTabs(in folder: String) {
    stoppedFolders.remove(folder)
  }

  /// Deletes the folder's logs, then its records and selection, after it was archived.
  func forgetTabs(in folder: String) async {
    for record in state.tabs where record.folder == folder {
      await history.delete(record.id)
    }
    $state.withLock { state in
      state.tabs.removeAll { $0.folder == folder }
      state.selectedTabIDs[folder] = nil
    }
    await save()
    stoppedFolders.remove(folder)
  }

  /// Stops every tab and returns once their output is saved. No tab starts after this.
  func quitConfirmed() async {
    isQuitting = true
    await withTaskGroup { group in
      for tab in tabs {
        group.addTask { await tab.stop() }
      }
    }
    await save()
  }

  // MARK: - Private Helpers

  private func tabs(in folder: String) -> [TerminalTabModel] {
    state.tabs.filter { $0.folder == folder }.compactMap { tabs[id: $0.id] }
  }

  private func hasTerminalTab(in folder: String) -> Bool {
    state.tabs.contains { record in
      guard case .terminal = record.kind else { return false }
      return record.folder == folder
    }
  }

  private func canStartTabs(in folder: String?) -> Bool {
    !isQuitting && !(folder.map(stoppedFolders.contains) ?? false)
  }

  /// The record is saved before the tab starts, so its log never exists without it.
  private func addTerminal(in folder: String) async {
    guard canStartTabs(in: folder) else { return }
    let record = TerminalTabRecord(
      id: uuid(), folder: folder, kind: .terminal(number: state.nextTerminalNumber(in: folder)))
    $state.withLock { state in
      state.tabs.append(record)
      state.selectedTabIDs[folder] = record.id
    }
    await save()
    await startShownTabs()
  }

  private func startShownTabs() async {
    let starting = state.tabs(shownIn: folder, listed: listedFolders)
      .filter { tabs[id: $0.id] == nil && canStartTabs(in: $0.folder) }
      .map { record in
        let tab = withDependencies(from: self) { TerminalTabModel(id: record.id) }
        tab.surface.onFocusChange = { [weak self] isFocused in
          self?.terminalFocusChanged(record.id, isFocused: isFocused)
        }
        tabs.append(tab)
        return tab
      }
    await withTaskGroup { group in
      for tab in starting {
        group.addTask { await tab.start() }
      }
    }
  }

  /// Stop, then delete the log, then remove the record: a log never outlives its record.
  private func close(_ tab: TerminalTabModel) async {
    let folder = state.tabs[id: tab.id]?.folder
    await tab.stop()
    await history.delete(tab.id)
    $state.withLock { state in
      state.tabs.remove(id: tab.id)
      if let folder, state.selectedTabIDs[folder] == tab.id { state.selectedTabIDs[folder] = nil }
    }
    tabs[id: tab.id] = nil
    await save()
    if let folder, folder == self.folder, !hasTerminalTab(in: folder) {
      await addTerminal(in: folder)
    }
  }

  private func save() async {
    await withErrorReporting { try await $state.save() }
  }
}

enum TerminalTabStatusIcon: Equatable {
  case running, finished, failed
}
