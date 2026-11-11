import Dependencies
import Foundation
import SlipstreamCore

@MainActor
@Observable
final class PRStatusBarModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.repoCommand) var repoCommand
  @ObservationIgnored @Dependency(\.continuousClock) var clock

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

  let chat: ChatPageModel
  private(set) var checked: Checked?
  private(set) var operation: Operation?
  private var refreshCount = 0

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

  // MARK: - Display Text

  static let checkFailedTitle = "Couldn't check the pull request"

  // MARK: - User Actions

  /// Run by the view as `.task(id: pollKey)`: any key change cancels it and starts a new one.
  func pollTask() async {
    guard let folder = chat.folder, chat.isAppActive, operation == nil else { return }
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

  // MARK: - Private Helpers

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
    _ = try Self.output(of: origin, title: title)

    let repository = try await decoded(
      GitHubRepository.self,
      ["gh", "repo", "view", "--json", "isFork,defaultBranchRef,viewerDefaultMergeMethod"],
      in: folder, title: title)
    guard !repository.isFork else { return nil }

    let uncommitted = try await uncommittedCount(in: folder, title: title)
    let pullRequests = try await decoded(
      [GitHubPullRequest].self,
      [
        "gh", "pr", "list", "--head", branch, "--state", "all", "--limit", "20", "--json",
        "number,url,state,isDraft,headRefOid,isCrossRepository,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup",
      ],
      in: folder, title: title)
    let pullRequest = PRStatus.selectPullRequest(pullRequests, head: head, uncommitted: uncommitted)

    var snapshot = RepoSnapshot(
      head: head, branch: branch, uncommittedCount: uncommitted, defaultBranch: repository.defaultBranch,
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
