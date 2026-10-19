import Dependencies
import Foundation
import IdentifiedCollections
import Sharing

@MainActor
@Observable
final class ChatPageModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.continuousClock) var clock
  @ObservationIgnored @Dependency(\.uuid) var uuid

  // MARK: - Shared State

  @ObservationIgnored @Shared(.chatTabs) var records

  // MARK: - Initialization

  override init() {
    super.init()
    for record in records { addModel(for: record.id, needsHistory: true) }
  }

  // MARK: - Properties

  var tabs: IdentifiedArrayOf<ChatTabModel> = []
  var folder: String?
  private var emptyText: String?
  private var selectedTabIDs: [String: UUID] = [:]
  private(set) var isQuitting = false
  private(set) var isComparisonShown = false
  private var isAppActive = true
  private var hoveredTabID: UUID?

  var visibleTabs: [ChatTabModel] {
    guard let folder else { return [] }
    return records.filter { $0.folder == folder }.compactMap { tabs[id: $0.id] }
  }

  var selectedTab: ChatTabModel? {
    let visible = visibleTabs
    let selectedID = folder.flatMap { selectedTabIDs[$0] }
    return visible.first { $0.id == selectedID } ?? visible.first
  }

  /// Counts every folder's tabs, shown or not.
  var workingTabCount: Int { tabs.filter(\.isWorking).count }

  /// The message box edits the shown tab's draft; with no tab there is nothing to edit.
  var draft: String {
    get { selectedTab?.draft ?? "" }
    set { selectedTab?.draft = newValue }
  }

  var isMessageBoxEnabled: Bool { selectedTab != nil && !isQuitting }
  var isPickerEnabled: Bool { isMessageBoxEnabled && selectedTab?.isPickerEnabled == true }
  var showsStop: Bool { selectedTab?.showsStop ?? false }
  var showsNewTabButton: Bool { folder != nil }

  // MARK: - Display Text

  let placeholderText = "Ask to make changes, @mention files, run /commands"
  let tryAgainText = "Try again"
  let quitAlertTitle = "Quit Slipstream?"
  let quitText = "Quit"
  let cancelText = "Cancel"

  var noWorkspaceText: String? { folder == nil ? emptyText : nil }

  var pickerText: String {
    selectedTab?.pickerText
      ?? ChatTabModel.pickerText(model: ChatModelChoice.defaultModel, effort: ChatModelChoice.defaultEffort)
  }

  var quitAlertText: String? {
    let count = workingTabCount
    guard count > 0 else { return nil }
    let tabs = count == 1 ? "1 tab" : "\(count) tabs"
    return "Claude is still working in \(tabs). Quitting stops them. You can pick the conversations up again next time."
  }

  // MARK: - View Helpers

  func isWaiting(folder: String) -> Bool {
    records.contains { $0.folder == folder && $0.isWaiting }
  }

  func isSelected(_ tab: ChatTabModel) -> Bool { selectedTab?.id == tab.id }

  func isHovered(_ tab: ChatTabModel) -> Bool { hoveredTabID == tab.id }

  // MARK: - User Actions

  /// Loads the shown tab's history the first time it is shown. Call it again whenever
  /// `selectedTab` changes.
  func viewAppeared() async {
    await selectedTab?.shown()
  }

  /// Ticks every working tab's clock once a second. Runs for the page's lifetime.
  func clockTask() async {
    while (try? await clock.sleep(for: .seconds(1))) != nil {
      for tab in tabs { tab.clockTicked() }
    }
  }

  func appActivityChanged(isActive: Bool) {
    isAppActive = isActive
  }

  func comparisonVisibilityChanged(isShown: Bool) {
    isComparisonShown = isShown
  }

  func workspaceChanged(folder: String?, emptyText: String?) {
    self.folder = folder
    self.emptyText = emptyText
    if let folder, visibleTabs.isEmpty {
      addTab(in: folder, model: ChatModelChoice.defaultModel, effort: ChatModelChoice.defaultEffort)
    }
  }

  func tabHovered(_ id: UUID, isHovering: Bool) {
    if isHovering {
      hoveredTabID = id
    } else if hoveredTabID == id {
      hoveredTabID = nil
    }
  }

  func newTabTapped() async {
    guard let folder else { return }
    let current = selectedTab?.record
    addTab(
      in: folder,
      model: current?.model ?? ChatModelChoice.defaultModel,
      effort: current?.effort ?? ChatModelChoice.defaultEffort
    )
  }

  func tabSelected(_ id: UUID) async {
    guard let folder, let tab = visibleTabs.first(where: { $0.id == id }) else { return }
    selectedTabIDs[folder] = id
    await tab.shown()
  }

  func closeTabTapped(_ id: UUID) async {
    let visible = visibleTabs
    guard let folder, let index = visible.firstIndex(where: { $0.id == id }) else { return }
    let tab = visible[index]
    if selectedTab?.id == id {
      let neighbour = index > 0 ? visible[index - 1] : visible.dropFirst().first
      selectedTabIDs[folder] = neighbour?.id
    }
    $records.withLock { $0[id: id] = nil }
    if visibleTabs.isEmpty {
      addTab(in: folder, model: tab.record.model, effort: tab.record.effort)
    }
    await tab.close()
    tabs[id: id] = nil
  }

  func closeShortcutPressed() async {
    guard !isComparisonShown, let id = selectedTab?.id else { return }
    await closeTabTapped(id)
  }

  func sendTapped() async {
    guard !isQuitting else { return }
    await selectedTab?.send()
  }

  func stopTapped() async {
    await selectedTab?.stop()
  }

  func tryAgainTapped() async {
    guard !isQuitting else { return }
    await selectedTab?.tryAgain()
  }

  func choiceSelected(model: String, effort: ChatEffort) async {
    await selectedTab?.choiceSelected(model: model, effort: effort)
  }

  func modelSelected(_ model: String) async {
    guard let tab = selectedTab else { return }
    await tab.choiceSelected(model: model, effort: tab.record.effort)
  }

  func effortSelected(_ effort: ChatEffort) async {
    guard let tab = selectedTab else { return }
    await tab.choiceSelected(model: tab.record.model, effort: effort)
  }

  /// Stops every agent and returns once they have all exited. Nothing can be sent after this.
  func quitConfirmed() async {
    isQuitting = true
    await withTaskGroup { group in
      for tab in tabs {
        group.addTask { await tab.close() }
      }
    }
  }

  // MARK: - Private Helpers

  private func addTab(in folder: String, model: String, effort: ChatEffort) {
    let record = ChatTabRecord(id: uuid(), folder: folder, model: model, effort: effort, isWaiting: false)
    $records.withLock { _ = $0.append(record) }
    addModel(for: record.id, needsHistory: false)
    selectedTabIDs[folder] = record.id
  }

  private func addModel(for id: UUID, needsHistory: Bool) {
    guard let record = Shared($records[id: id]) else { return }
    let tab = withDependencies(from: self) {
      ChatTabModel(record: record, needsHistory: needsHistory)
    }
    tab.onTurnEnded = { [weak self] in self?.turnEnded(id) }
    tabs.append(tab)
  }

  /// A turn that ends while its tab isn't on screen leaves the tab waiting.
  private func turnEnded(_ id: UUID) {
    guard !isAppActive || isComparisonShown || selectedTab?.id != id else { return }
    $records.withLock { $0[id: id]?.isWaiting = true }
  }
}
