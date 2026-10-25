import Dependencies
import Foundation
import IdentifiedCollections
import Sharing
import SlipstreamCore

@MainActor
@Observable
final class ChatPageModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.chatLink) var chatLink
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
  /// Each folder's binding from the last capture read; `nil` until a read succeeds.
  private var bindings: [String: CaptureBinding]?
  private var linkFailures: [UUID: LinkRefusal] = [:]
  /// The folder just shown: its next capture read is the moment its window opens.
  private var openingFolder: String?
  /// Tabs closed while they were connecting, by folder: if the next capture read shows one linked,
  /// its link moves off. Any outcome counts, since a refused attach can still have linked.
  private var strandedLinks: [UUID: String] = [:]

  /// Set by the window: re-reads the captures, which arrive back through `capturesArrived`.
  @ObservationIgnored var onLinkChanged: @MainActor () async -> Void = {}
  @ObservationIgnored var onReadinessChanged: @MainActor () -> Void = {}
  /// Called once each time a tab's turn ends, with the tab's id.
  @ObservationIgnored var onTabTurnEnded: (UUID) -> Void = { _ in }
  /// Called once per relay a tab was sent, with the tab's id.
  @ObservationIgnored var onRelayDelivery: (UUID, RelayDelivery) -> Void = { _, _ in }

  var visibleTabs: [ChatTabModel] {
    guard let folder else { return [] }
    return tabs(in: folder)
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
  let newTabAccessibilityLabel = "New chat"
  let sendAccessibilityLabel = "Send message"
  let stopAccessibilityLabel = "Stop reply"
  let quitAlertTitle = "Quit Slipstream?"
  let quitText = "Quit"
  let cancelText = "Cancel"

  let connectText = "Connect to Stream"
  let closeTabText = "Close Tab"

  var noWorkspaceText: String? { folder == nil ? emptyText : nil }

  var outsideChatText: String? {
    guard let folder, let binding = bindings?[folder], binding.isLive,
      !tabs(in: folder).contains(where: { binding.isLinked(toChat: $0.id) })
    else { return nil }
    return "Stream: outside chat"
  }

  func linkHoverTitle(for tab: ChatTabModel) -> String? {
    switch linkIcon(for: tab) {
    case .connected, .waiting: "Connected to Stream"
    case .failed: "Couldn't connect to Stream"
    case nil: nil
    }
  }

  func connectHintText(for tab: ChatTabModel) -> String? {
    isConnectEnabled(tab) ? nil : "Send this chat a message first."
  }

  /// The icon's tooltip: the hover title, then its explanation on the next line.
  func linkHelpText(for tab: ChatTabModel) -> String? {
    guard let title = linkHoverTitle(for: tab) else { return nil }
    return [title, linkHoverText(for: tab)].compactMap(\.self).joined(separator: "\n")
  }

  func linkHoverText(for tab: ChatTabModel) -> String? {
    if let refusal = linkFailures[tab.id] { return Self.text(for: refusal) }
    guard linkIcon(for: tab) == .waiting else { return nil }
    return "Waiting for it to confirm. It connects the next time the agent works — send it a message to connect now."
  }

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

  func hasWorkingTab(in folder: String) -> Bool {
    records.contains { $0.folder == folder && tabs[id: $0.id]?.isWorking == true }
  }

  func isSelected(_ tab: ChatTabModel) -> Bool { selectedTab?.id == tab.id }

  func isHovered(_ tab: ChatTabModel) -> Bool { hoveredTabID == tab.id }

  func isConnectEnabled(_ tab: ChatTabModel) -> Bool { tab.hasSentMessage }

  /// Blue when connected, amber while it confirms. While nothing is linked and no chat has sent
  /// a message, the first tab waits: auto-link will pick it.
  func linkIcon(for tab: ChatTabModel) -> ChatLinkIcon? {
    if linkFailures[tab.id] != nil { return .failed }
    let folder = tab.record.folder
    if let binding = bindings?[folder], binding.isLinked(toChat: tab.id) {
      return binding.state == .connected ? .connected : .waiting
    }
    let strip = tabs(in: folder)
    guard isUnlinked(folder), strip.first?.id == tab.id, !strip.contains(where: \.hasSentMessage) else { return nil }
    return .waiting
  }

  /// A linked app tab answers once it has sent a message; anything else keeps the outside chat's checks.
  func askRoute(forFolder folder: String) -> AskRoute {
    guard let tab = linkedAppTab(forFolder: folder) else { return .outside }
    return tab.hasSentMessage ? .app : .none
  }

  /// The tab the folder's binding names, if it is one of the app's tabs.
  func linkedAppTab(forFolder folder: String) -> ChatTabModel? {
    guard let binding = bindings?[folder] else { return nil }
    return tabs(in: folder).first { binding.isLinked(toChat: $0.id) }
  }

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
    openingFolder = folder
    if let folder {
      for record in records where record.folder == folder && tabs[id: record.id] == nil {
        addModel(for: record.id, needsHistory: true)
      }
    }
    if let folder, visibleTabs.isEmpty {
      addTab(in: folder, model: ChatModelChoice.defaultModel, effort: ChatModelChoice.defaultEffort)
    }
    windowOpenedIfReady()
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

  /// Called with every capture read; `nil` when the read failed or lists no captures.
  func capturesArrived(_ captures: [CaptureSummary]?) {
    guard let captures else {
      bindings = nil
      return
    }
    let folders = Set(captures.map { ChangeStreamPageModel.normalizedFolder($0.root) })
    let bindings = Dictionary(uniqueKeysWithValues: folders.compactMap { folder in
      captures.current(in: folder)?.binding.map { (folder, $0) }
    })
    self.bindings = bindings
    for (id, folder) in strandedLinks {
      strandedLinks[id] = nil
      guard let binding = bindings[folder], binding.isLive, binding.isLinked(toChat: id) else { continue }
      Task { [weak self] in await self?.linkedTabClosed(in: folder, generation: binding.generation) }
    }
    linkFailures = linkFailures.filter { id, _ in
      guard let folder = records[id: id]?.folder, let binding = bindings[folder] else { return true }
      return !(binding.isLinked(toChat: id) && binding.state == .connected)
    }
    windowOpenedIfReady()
  }

  func connectTapped(_ id: UUID) async {
    guard let folder, let tab = visibleTabs.first(where: { $0.id == id }), isConnectEnabled(tab) else { return }
    linkFailures[id] = nil
    let live = bindings?[folder].flatMap { $0.isLive ? $0 : nil }
    await linkFinished(await chatLink.link(folder, id, live?.generation), for: id, in: folder)
  }

  func closeTabTapped(_ id: UUID) async {
    let visible = visibleTabs
    guard let folder, let index = visible.firstIndex(where: { $0.id == id }) else { return }
    let tab = visible[index]
    let linked = bindings?[folder].flatMap { $0.isLinked(toChat: id) ? $0 : nil }
    linkFailures[id] = nil
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
    if let linked {
      await linkedTabClosed(in: folder, generation: linked.generation)
    } else if bindings == nil {
      strandedLinks[id] = folder
    }
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

  /// Stops every agent in `folder` and returns once they have all exited. The
  /// conversations are kept: showing the folder again reopens them.
  func stopTabs(in folder: String) async -> [UUID: String] {
    let stopping = records.filter { $0.folder == folder }.compactMap { tabs[id: $0.id] }
    let drafts = Dictionary(uniqueKeysWithValues: stopping.map { ($0.id, $0.draft) })
    await withTaskGroup { group in
      for tab in stopping {
        group.addTask { await tab.close() }
      }
    }
    for tab in stopping { tabs[id: tab.id] = nil }
    return drafts
  }

  func restoreTabs(in folder: String, drafts: [UUID: String]) {
    for (id, draft) in drafts where records[id: id]?.folder == folder {
      tabs[id: id]?.draft = draft
    }
  }

  func forgetTabs(in folder: String) {
    $records.withLock { $0.removeAll { $0.folder == folder } }
    selectedTabIDs[folder] = nil
  }

  // MARK: - Private Helpers

  private func tabs(in folder: String) -> [ChatTabModel] {
    records.filter { $0.folder == folder }.compactMap { tabs[id: $0.id] }
  }

  /// Unknown, `unavailable` and unrecognised bindings are never linked over.
  private func isUnlinked(_ folder: String) -> Bool {
    guard let bindings else { return false }
    guard let binding = bindings[folder] else { return true }
    return binding.state == .unlinked
  }

  /// Loads every tab's history first, so the Connect to Stream menu knows which can link.
  private func firstTabWithMessage(in folder: String) async -> ChatTabModel? {
    for tab in tabs(in: folder) { await tab.shown() }
    return tabs(in: folder).first(where: \.hasSentMessage)
  }

  /// Two auto-links can overlap; `link(replacing: nil)` skips once anything is linked.
  private func autoLink(in folder: String) async {
    guard let tab = await firstTabWithMessage(in: folder), isUnlinked(folder) else { return }
    await linkFinished(await chatLink.link(folder, tab.id, nil), for: tab.id, in: folder)
  }

  private func linkedTabClosed(in folder: String, generation: String) async {
    if let next = await firstTabWithMessage(in: folder) {
      await linkFinished(await chatLink.link(folder, next.id, generation), for: next.id, in: folder)
    } else {
      await linkFinished(await chatLink.unlink(folder, generation), for: nil, in: folder)
    }
  }

  private func linkFinished(_ outcome: LinkOutcome, for id: UUID?, in folder: String) async {
    if let id, records[id: id] != nil {
      switch outcome {
      case .linked: tabs[id: id]?.streamLinked()
      case .refused(let refusal): linkFailures[id] = refusal
      case .unlinked, .skipped, .retryLater: break
      }
    } else if let id {
      strandedLinks[id] = folder
    }
    await onLinkChanged()
  }

  /// The window opens once both its folder and a capture read are known, in either order.
  private func windowOpenedIfReady() {
    guard let folder, openingFolder == folder, bindings != nil else { return }
    openingFolder = nil
    Task { [weak self] in await self?.autoLink(in: folder) }
  }

  private static func text(for refusal: LinkRefusal) -> String {
    let retry = "right-click the tab and choose Connect to Stream to try again."
    switch refusal {
    case .slipstreamTooOld:
      return "This version of Slipstream can't connect chats run in the app. Update Slipstream, then \(retry)"
    case .slotsFull:
      return "Slipstream is already connected to 10 chats, its limit. Unlink one with `slipstream unlink`, then \(retry)"
    case .setupIncomplete(let message), .other(let message):
      return "Slipstream said: \(message) Right-click the tab and choose Connect to Stream to try again."
    }
  }

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
    tab.onReadinessChanged = { [weak self] in self?.onReadinessChanged() }
    tab.onRelayDelivery = { [weak self] delivery in self?.onRelayDelivery(id, delivery) }
    tabs.append(tab)
  }

  /// A turn that ends while its tab isn't on screen leaves the tab waiting. While nothing is
  /// linked, every turn end tries an auto-link.
  private func turnEnded(_ id: UUID) {
    if !isAppActive || isComparisonShown || selectedTab?.id != id {
      $records.withLock { $0[id: id]?.isWaiting = true }
    }
    if let folder = records[id: id]?.folder, isUnlinked(folder) {
      Task { [weak self] in await self?.autoLink(in: folder) }
    }
    onTabTurnEnded(id)
  }
}

enum ChatLinkIcon: Equatable {
  case connected, waiting, failed
}
