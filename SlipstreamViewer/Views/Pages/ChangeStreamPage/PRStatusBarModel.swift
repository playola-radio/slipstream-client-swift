import Dependencies
import Foundation
import SlipstreamCore
import SwiftUI

enum PRStatusTone: Equatable, Sendable {
  case neutral, muted, success, warning, danger, merged
}

enum PRBarButton: Equatable, Sendable {
  case createPR, commitAndPush, resolveConflicts, fixErrors, merge

  var title: String {
    switch self {
    case .createPR: "Create PR"
    case .commitAndPush: "Commit and push"
    case .resolveConflicts: "Resolve conflicts"
    case .fixErrors: "Fix errors"
    case .merge: "Merge"
    }
  }

  var iconName: String {
    switch self {
    case .createPR: "GitPullRequestCreate"
    case .commitAndPush: "GitCommitHorizontal"
    case .resolveConflicts: "GitCompareArrows"
    case .fixErrors: "Wrench"
    case .merge: "GitMerge"
    }
  }

  var shortcut: KeyboardShortcut? {
    switch self {
    case .createPR: KeyboardShortcut("p", modifiers: [.command, .shift])
    case .fixErrors: KeyboardShortcut("x", modifiers: [.command, .shift])
    case .merge: KeyboardShortcut("m", modifiers: [.command, .shift])
    case .commitAndPush, .resolveConflicts: nil
    }
  }

  var shortcutText: String? {
    switch self {
    case .createPR: "⌘⇧P"
    case .fixErrors: "⌘⇧X"
    case .merge: "⌘⇧M"
    case .commitAndPush, .resolveConflicts: nil
    }
  }
}

@MainActor
@Observable
final class PRStatusBarModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.repoCommand) var repoCommand
  @ObservationIgnored @Dependency(\.attachments) var attachments
  @ObservationIgnored @Dependency(\.continuousClock) var clock
  @ObservationIgnored @Dependency(\.pasteboard) var pasteboard

  // MARK: - Initialization

  init(chat: ChatPageModel) {
    self.chat = chat
    super.init()
  }

  // MARK: - Properties

  static let gitTimeout: Duration = .seconds(10)
  static let ghReadTimeout: Duration = .seconds(20)
  static let longTimeout: Duration = .seconds(60)
  static let pollInterval: Duration = .seconds(30)

  struct PollKey: Hashable {
    var folder: String?
    var isAppActive: Bool
    var refreshCount: Int
    var isOperationInFlight: Bool
    var isChatWorking: Bool
  }

  struct Checked: Equatable {
    var folder: String
    var result: Result<RepoSnapshot?, PRBarFailure>
  }

  enum Operation: Equatable {
    case merging, continuing, sending
  }

  private struct FailedAction {
    var folder: String
    var failure: PRBarFailure
  }

  let chat: ChatPageModel
  private(set) var checked: Checked?
  private(set) var operation: Operation?
  private(set) var isDetailsPresented = false
  private var failedAction: FailedAction?
  private var refreshCount = 0
  /// Set by the owner: whether the selected workspace can be archived.
  @ObservationIgnored var isArchivable: @MainActor () -> Bool = { false }
  @ObservationIgnored var onArchive: @MainActor () -> Void = {}

  var pollKey: PollKey {
    PollKey(
      folder: chat.folder,
      isAppActive: chat.isAppActive,
      refreshCount: refreshCount,
      isOperationInFlight: operation != nil,
      isChatWorking: chat.folder.map(chat.hasWorkingTab(in:)) ?? false
    )
  }

  /// `nil` while the feature doesn't apply to the selected folder or it hasn't been read yet.
  var snapshot: RepoSnapshot? {
    guard let result = currentResult, case .success(let snapshot) = result else { return nil }
    return snapshot
  }

  var status: PRStatus? { snapshot.map(PRStatus.init(snapshot:)) }

  var checkFailure: PRBarFailure? {
    guard let result = currentResult, case .failure(let failure) = result else { return nil }
    return failure
  }

  var isCheckingShown: Bool { chat.folder != nil && currentResult == nil }

  /// Stays until Details is dismissed, the action is retried or the workspace changes.
  var actionFailure: PRBarFailure? {
    guard let failedAction, failedAction.folder == chat.folder else { return nil }
    return failedAction.failure
  }

  var failure: PRBarFailure? { actionFailure ?? checkFailure }

  // MARK: - Display Text

  static let checkFailedTitle = "Couldn't check the pull request"
  static let mergeFailedTitle = "Merge failed"
  static let continueFailedTitle = "Couldn't start a new branch"
  static let continueText = "Continue"
  static let archiveText = "Archive"
  static let detailsText = "Details"
  static let copyText = "Copy"

  var prNumberText: String? { snapshot?.pullRequest.map { "#\($0.number)" } }

  var pullRequestURL: URL? { snapshot?.pullRequest?.url }

  var statusLabel: String { appearance.label }

  var statusDetail: String? { appearance.detail }

  // MARK: - View Helpers

  var isRowContentShown: Bool {
    if failure != nil || isCheckingShown { return true }
    guard let status else { return false }
    return status != .nothingToSubmit
  }

  var statusIconName: String? { appearance.iconName }

  var tone: PRStatusTone { appearance.tone }

  var primaryButton: PRBarButton? {
    switch status {
    case .noPRUncommitted?, .noPRCommitted?, .closed?: .createPR
    case .commitAndPush?: .commitAndPush
    case .conflicts?: .resolveConflicts
    case .checksFailed?: .fixErrors
    case .ready?: .merge
    case nil, .nothingToSubmit?, .checksRunning?, .draft?, .waiting?, .merged?: nil
    }
  }

  /// Agent buttons also wait while any chat tab in the workspace is working.
  var isPrimaryButtonEnabled: Bool {
    guard operation == nil, let folder = chat.folder else { return false }
    return primaryButton == .merge || !chat.hasWorkingTab(in: folder)
  }

  var isContinueShown: Bool { status == .merged }

  /// Waits like the agent buttons: switching branches under a working agent would move its files.
  var isContinueEnabled: Bool {
    guard operation == nil, let folder = chat.folder else { return false }
    return !chat.hasWorkingTab(in: folder)
  }

  var isArchiveShown: Bool { isContinueShown && isArchivable() }

  var isDetailsShown: Bool { failure != nil }

  var isDetailsPopoverPresented: Bool {
    get { isDetailsPresented }
    set {
      if newValue { detailsTapped() } else { detailsDismissed() }
    }
  }

  // MARK: - User Actions

  /// Run by the view as `.task(id: pollKey)`: any key change cancels it and starts a new one.
  func pollTask() async {
    guard let folder = chat.folder, chat.isAppActive, operation == nil else { return }
    if failedAction?.folder != folder { failedAction = nil }
    while true {
      let result = await readSnapshot(folder: folder)
      guard !Task.isCancelled else { return }
      checked = Checked(folder: folder, result: result)
      do { try await clock.sleep(for: Self.pollInterval) } catch { return }
    }
  }

  func reloadRequested() {
    refreshCount += 1
  }

  func primaryButtonTapped() async {
    guard let button = primaryButton, isPrimaryButtonEnabled, let folder = chat.folder, let snapshot else { return }
    failedAction = nil
    switch button {
    case .createPR:
      await send(button, in: folder) { [self] title throws(PRBarFailure) in
        try await createPRMessage(snapshot, in: folder, title: title)
      }
    case .commitAndPush:
      await send(button, in: folder) { _ in PRInstructions.commitAndPushMessage }
    case .resolveConflicts:
      await send(button, in: folder) { _ in PRInstructions.resolveConflictsMessage(target: Self.target(of: snapshot)) }
    case .fixErrors:
      await send(button, in: folder) { [self] title throws(PRBarFailure) in
        try await fixErrorsMessage(snapshot, in: folder, title: title)
      }
    case .merge:
      await merge(snapshot, in: folder)
    }
  }

  /// Starts the next branch from the latest target (spec "Actions → Continue").
  func continueTapped() async {
    guard isContinueShown, isContinueEnabled, let folder = chat.folder, let snapshot else { return }
    failedAction = nil
    operation = .continuing
    defer { operation = nil }
    let title = Self.continueFailedTitle
    let target = Self.target(of: snapshot)
    do throws(PRBarFailure) {
      _ = try await output(
        ["git", "fetch", "origin", "+refs/heads/\(target):refs/remotes/origin/\(target)"], in: folder,
        timeout: Self.longTimeout, title: title)
      let local = try await output(
        ["git", "for-each-ref", "--format=%(refname:short)", "refs/heads"], in: folder, timeout: Self.gitTimeout,
        title: title)
      let remote = try await output(
        ["git", "ls-remote", "--heads", "origin"], in: folder, timeout: Self.gitTimeout, title: title)
      let taken = local.split(separator: "\n").map(String.init) + Self.remoteBranches(remote)
      let name = PRInstructions.nextBranchName(after: snapshot.branch, taken: Set(taken))
      if let change = try await changeSinceMerge(snapshot, in: folder, title: title) {
        reloadRequested()
        throw PRBarFailure(title: title, details: "Folder: \(folder)\n\(change)")
      }
      _ = try await output(
        ["git", "switch", "--no-track", "-c", name, "origin/\(target)"], in: folder, timeout: Self.gitTimeout,
        title: title)
    } catch {
      failedAction = FailedAction(folder: folder, failure: error)
    }
  }

  func archiveTapped() {
    onArchive()
  }

  func detailsTapped() {
    isDetailsPresented = true
  }

  func detailsDismissed() {
    isDetailsPresented = false
    failedAction = nil
  }

  func copyTapped() {
    guard let failure else { return }
    pasteboard.copy("\(failure.title)\n\n\(failure.details)")
  }

  // MARK: - Private Helpers

  private var appearance: (label: String, detail: String?, iconName: String?, tone: PRStatusTone) {
    if let failure { return (failure.title, nil, "CircleAlert", .danger) }
    if operation == .merging { return ("Merging…", nil, "LoaderCircle", .muted) }
    if isCheckingShown { return ("Checking for a pull request…", nil, "LoaderCircle", .muted) }
    switch status {
    case nil, .nothingToSubmit?:
      return ("", nil, nil, .muted)
    case .noPRUncommitted?, .commitAndPush?:
      return ("Uncommitted changes", nil, nil, .neutral)
    case .noPRCommitted(let ahead, let target)?:
      let commits = ahead == 1 ? "1 commit" : "\(ahead) commits"
      return ("Ready for a pull request", "· \(commits) ahead of \(target)", nil, .neutral)
    case .conflicts(let target)?:
      return ("Merge conflicts", "with \(target)", "TriangleAlert", .warning)
    case .checksFailed(let failed, let total)?:
      return ("Checks failed", "· \(failed) of \(total) failed", "CircleX", .danger)
    case .checksRunning(let done, let total)?:
      return ("Checks running", "· \(done) of \(total) done", "LoaderCircle", .muted)
    case .draft?:
      return ("Draft", "· all checks passed", "GitPullRequestDraft", .muted)
    case .ready?:
      return ("Ready to merge", nil, "CircleCheck", .success)
    case .waiting(let reason)?:
      return ("Waiting on GitHub", "· \(Self.text(for: reason))", "Hourglass", .muted)
    case .merged?:
      return ("Merged", nil, "GitMerge", .merged)
    case .closed?:
      return ("Closed", nil, "GitPullRequestClosed", .muted)
    }
  }

  private static func text(for reason: WaitingReason) -> String {
    switch reason {
    case .gitHubChecking: "GitHub is still checking"
    case .changesRequested: "changes requested"
    case .reviewRequired: "review required"
    case .behind(let target): "behind \(target)"
    case .blocked: "blocked by branch rules"
    case .outOfSync: "branch is out of sync with the PR"
    case .notMergeable: "not mergeable yet"
    }
  }

  private static func target(of snapshot: RepoSnapshot) -> String {
    snapshot.pullRequest?.baseRefName ?? snapshot.defaultBranch
  }

  /// Spec "Actions → Agent buttons": the tab is captured at click, and nothing is sent when composing fails.
  private func send(
    _ button: PRBarButton, in folder: String,
    message: (_ failureTitle: String) async throws(PRBarFailure) -> String
  ) async {
    operation = .sending
    defer { operation = nil }
    if chat.selectedTab == nil { await chat.newTabTapped() }
    guard let tab = chat.selectedTab else { return }
    let title = "Couldn't send \(button.title)"
    do throws(PRBarFailure) {
      let text = try await message(title)
      do {
        try await tab.enqueueUserMessage(text)
      } catch {
        let reason = tab.isClosed ? "The chat tab was closed, so nothing was sent." : "Couldn't send the message: \(error)"
        throw PRBarFailure(title: title, details: "Folder: \(folder)\n\(reason)")
      }
    } catch {
      failedAction = FailedAction(folder: folder, failure: error)
    }
  }

  private func createPRMessage(_ snapshot: RepoSnapshot, in folder: String, title: String)
    async throws(PRBarFailure) -> String
  {
    let branch = try await output(
      ["git", "rev-parse", "--abbrev-ref", "HEAD"], in: folder, timeout: Self.gitTimeout, title: title)
    let uncommitted = try await uncommittedCount(in: folder, title: title)
    let upstream = try await upstream(in: folder, title: title)
    let instructions = PRInstructions.createPR(
      uncommitted: uncommitted, branch: branch, target: Self.target(of: snapshot), upstream: upstream)
    return try attach(
      PRInstructions.createPRMessage, name: "PR instructions.md", contents: instructions, in: folder, title: title)
  }

  private func upstream(in folder: String, title: String) async throws(PRBarFailure) -> PRInstructions.Upstream {
    let result = await run(["git", "rev-parse", "--abbrev-ref", "@{upstream}"], in: folder, timeout: Self.gitTimeout)
    if result.ending == .exit(128) { return .none }
    let name = try Self.output(of: result, title: title)
    let command = ["git", "rev-list", "--count", "@{upstream}..HEAD"]
    let unpushed = try Self.count(
      try await output(command, in: folder, timeout: Self.gitTimeout, title: title), of: command, folder: folder,
      title: title)
    return unpushed == 0 ? .inSync(name) : .unpushed(unpushed)
  }

  /// A log that can't be fetched is replaced by the command and its output; the message is still sent.
  private func fixErrorsMessage(_ snapshot: RepoSnapshot, in folder: String, title: String)
    async throws(PRBarFailure) -> String
  {
    guard let pullRequest = snapshot.pullRequest else {
      throw PRBarFailure(title: title, details: "Folder: \(folder)\nThere is no pull request.")
    }
    var runs: [ActionsRun] = []
    for check in pullRequest.statusCheckRollup where check.outcome == .failed {
      if let actionsRun = check.link.flatMap(ActionsRun.init(link:)), !runs.contains(actionsRun) {
        runs.append(actionsRun)
      }
    }
    var logs: [ActionsRun: String] = [:]
    for actionsRun in runs {
      let result = await run(
        ["gh", "run", "view", actionsRun.id, "--repo", actionsRun.repository, "--log-failed"], in: folder,
        timeout: Self.longTimeout)
      logs[actionsRun] = result.succeeded ? result.stdout : PRBarFailure.details(of: result)
    }
    let instructions = PRInstructions.fixErrors(pullRequest: pullRequest, branch: snapshot.branch, logs: logs)
    return try attach(
      PRInstructions.fixErrorsMessage, name: "Fix errors instructions.md", contents: instructions, in: folder,
      title: title)
  }

  private func attach(_ message: String, name: String, contents: String, in folder: String, title: String)
    throws(PRBarFailure) -> String
  {
    do {
      let file = try attachments.write(name, contents)
      return "\(message) \(AttachmentMarker.format(name: name, path: file.path))"
    } catch {
      throw PRBarFailure(title: title, details: "Folder: \(folder)\nCouldn't write \(name): \(error)")
    }
  }

  /// Merged was shown for a clean worktree at the merged head; says what no longer holds.
  private func changeSinceMerge(_ snapshot: RepoSnapshot, in folder: String, title: String)
    async throws(PRBarFailure) -> String?
  {
    let branch = try await output(
      ["git", "rev-parse", "--abbrev-ref", "HEAD"], in: folder, timeout: Self.gitTimeout, title: title)
    if branch != snapshot.branch { return "The checked-out branch changed from \(snapshot.branch) to \(branch)." }
    let head = try await output(["git", "rev-parse", "HEAD"], in: folder, timeout: Self.gitTimeout, title: title)
    if head != snapshot.pullRequest?.headRefOid { return "HEAD moved since the PR merged." }
    if try await uncommittedCount(in: folder, title: title) > 0 { return "The branch has uncommitted changes." }
    if chat.hasWorkingTab(in: folder) { return "A chat in this folder started working." }
    return nil
  }

  private func merge(_ snapshot: RepoSnapshot, in folder: String) async {
    guard let pullRequest = snapshot.pullRequest else { return }
    operation = .merging
    defer { operation = nil }
    let result = await run(
      [
        "gh", "pr", "merge", pullRequest.url.absoluteString, Self.mergeFlag(snapshot.mergeMethod),
        "--match-head-commit", pullRequest.headRefOid,
      ], in: folder, timeout: Self.longTimeout)
    if !result.succeeded {
      failedAction = FailedAction(folder: folder, failure: PRBarFailure(title: Self.mergeFailedTitle, result: result))
    }
  }

  private static func mergeFlag(_ method: String) -> String {
    switch method {
    case "SQUASH": "--squash"
    case "REBASE": "--rebase"
    default: "--merge"
    }
  }

  /// Branch names from `git ls-remote --heads` lines (`<oid>\trefs/heads/<name>`).
  private static func remoteBranches(_ output: String) -> [String] {
    output.split(separator: "\n").compactMap { line in
      line.split(separator: "\t", maxSplits: 1).last.flatMap { ref in
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : nil
      }
    }
  }

  private var currentResult: Result<RepoSnapshot?, PRBarFailure>? {
    guard let checked, checked.folder == chat.folder else { return nil }
    return checked.result
  }

  private func readSnapshot(folder: String) async -> Result<RepoSnapshot?, PRBarFailure> {
    do {
      return .success(try await gatherSnapshot(folder: folder))
    } catch {
      return .failure(error)
    }
  }

  /// Spec "How the status is derived", steps 1–7. `nil` when the feature doesn't apply.
  private func gatherSnapshot(folder: String) async throws(PRBarFailure) -> RepoSnapshot? {
    let title = Self.checkFailedTitle
    let branchResult = await run(["git", "rev-parse", "--abbrev-ref", "HEAD"], in: folder, timeout: Self.gitTimeout)
    if branchResult.ending == .exit(128) { return nil }
    let branch = try Self.output(of: branchResult, title: title)
    guard branch != "HEAD" else { return nil }
    let head = try await output(["git", "rev-parse", "HEAD"], in: folder, timeout: Self.gitTimeout, title: title)
    let origin = await run(["git", "remote", "get-url", "origin"], in: folder, timeout: Self.gitTimeout)
    if origin.ending == .exit(2) { return nil }
    let originURL = try Self.output(of: origin, title: title)

    let repository = try await decoded(
      GitHubRepository.self,
      ["gh", "repo", "view", originURL, "--json", "isFork,defaultBranchRef,viewerDefaultMergeMethod,nameWithOwner"],
      in: folder, title: title)
    guard !repository.isFork else { return nil }

    let uncommitted = try await uncommittedCount(in: folder, title: title)
    let pullRequests = try await decoded(
      [GitHubPullRequest].self,
      [
        "gh", "pr", "list", "--repo", repository.nameWithOwner, "--head", branch, "--state", "all", "--limit", "20", "--json",
        "number,url,state,isDraft,headRefOid,isCrossRepository,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup",
      ],
      in: folder, title: title)
    let pullRequest = PRStatus.selectPullRequest(pullRequests, head: head, uncommitted: uncommitted)

    var snapshot = RepoSnapshot(
      branch: branch, uncommittedCount: uncommitted, defaultBranch: repository.defaultBranch,
      mergeMethod: repository.mergeMethod, pullRequest: pullRequest, pushState: nil, aheadOfTarget: nil)
    switch pullRequest?.state {
    case nil:
      let ahead = try await output(
        ["git", "rev-list", "--count", "origin/\(repository.defaultBranch)..HEAD"], in: folder,
        timeout: Self.gitTimeout, title: title)
      snapshot.aheadOfTarget = try Self.count(ahead, of: ["git", "rev-list"], folder: folder, title: title)
    case .open?:
      snapshot.pushState = try await pushState(head: head, pullRequestHead: pullRequest!.headRefOid, in: folder)
    case .merged?, .closed?:
      break
    }
    return snapshot
  }

  private func pushState(head: String, pullRequestHead: String, in folder: String) async throws(PRBarFailure)
    -> PushState
  {
    guard head != pullRequestHead else { return .inSync }
    let result = await run(
      ["git", "merge-base", "--is-ancestor", pullRequestHead, "HEAD"], in: folder, timeout: Self.gitTimeout)
    switch result.ending {
    case .exit(0): return .localAhead
    case .exit: return .outOfSync
    case .timedOut, .launchFailed: throw PRBarFailure(title: Self.checkFailedTitle, result: result)
    }
  }

  private func uncommittedCount(in folder: String, title: String) async throws(PRBarFailure) -> Int {
    let result = await run(["git", "status", "--porcelain=v1"], in: folder, timeout: Self.gitTimeout)
    guard result.succeeded else { throw PRBarFailure(title: title, result: result) }
    return result.stdout.split(separator: "\n").count
  }

  private func run(_ arguments: [String], in folder: String, timeout: Duration) async -> CommandResult {
    await repoCommand.run(arguments, URL(fileURLWithPath: folder), timeout)
  }

  private func output(_ arguments: [String], in folder: String, timeout: Duration, title: String)
    async throws(PRBarFailure) -> String
  {
    try Self.output(of: await run(arguments, in: folder, timeout: timeout), title: title)
  }

  private func decoded<Value: Decodable>(_ type: Value.Type, _ arguments: [String], in folder: String, title: String)
    async throws(PRBarFailure) -> Value
  {
    let result = await run(arguments, in: folder, timeout: Self.ghReadTimeout)
    guard result.succeeded else { throw PRBarFailure(title: title, result: result) }
    do {
      return try JSONDecoder().decode(type, from: Data(result.stdout.utf8))
    } catch {
      throw PRBarFailure(title: title, result: result, note: "Couldn't read the output: \(error)")
    }
  }

  /// Trimmed stdout of a successful command.
  private static func output(of result: CommandResult, title: String) throws(PRBarFailure) -> String {
    guard result.succeeded else { throw PRBarFailure(title: title, result: result) }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func count(_ text: String, of command: [String], folder: String, title: String)
    throws(PRBarFailure) -> Int
  {
    guard let count = Int(text) else {
      throw PRBarFailure(
        title: title, details: "Folder: \(folder)\n\(command.joined(separator: " ")) printed \"\(text)\", not a count.")
    }
    return count
  }
}
