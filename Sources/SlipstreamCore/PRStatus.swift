public enum PushState: Equatable, Sendable {
  case inSync
  case localAhead
  case outOfSync
}

/// The facts one status check gathered about the workspace's branch.
public struct RepoSnapshot: Equatable, Sendable {
  public var head: String
  public var branch: String
  public var uncommittedCount: Int
  public var defaultBranch: String
  public var mergeMethod: String
  public var pullRequest: GitHubPullRequest?
  /// Open pull request only.
  public var pushState: PushState?
  /// No pull request only.
  public var aheadOfTarget: Int?

  public init(
    head: String,
    branch: String,
    uncommittedCount: Int,
    defaultBranch: String,
    mergeMethod: String,
    pullRequest: GitHubPullRequest?,
    pushState: PushState?,
    aheadOfTarget: Int?
  ) {
    self.head = head
    self.branch = branch
    self.uncommittedCount = uncommittedCount
    self.defaultBranch = defaultBranch
    self.mergeMethod = mergeMethod
    self.pullRequest = pullRequest
    self.pushState = pushState
    self.aheadOfTarget = aheadOfTarget
  }
}

public enum WaitingReason: Equatable, Sendable {
  case gitHubChecking
  case changesRequested
  case reviewRequired
  case behind(target: String)
  case blocked
  case outOfSync
  case notMergeable
}

/// Where the branch's pull request stands. The pull request itself stays on the snapshot.
public enum PRStatus: Equatable, Sendable {
  case noPRUncommitted(count: Int)
  case noPRCommitted(ahead: Int, target: String)
  case nothingToSubmit
  case commitAndPush
  case conflicts(target: String)
  case checksFailed(failed: Int, total: Int)
  case checksRunning(done: Int, total: Int)
  case draft
  case ready
  case waiting(reason: WaitingReason)
  case merged
  case closed

  private static let readyMergeStates: Set<String> = ["CLEAN", "HAS_HOOKS", "UNSTABLE"]

  public init(snapshot: RepoSnapshot) {
    guard let pullRequest = snapshot.pullRequest else {
      if snapshot.uncommittedCount > 0 {
        self = .noPRUncommitted(count: snapshot.uncommittedCount)
      } else if let ahead = snapshot.aheadOfTarget, ahead > 0 {
        self = .noPRCommitted(ahead: ahead, target: snapshot.defaultBranch)
      } else {
        self = .nothingToSubmit
      }
      return
    }
    switch pullRequest.state {
    case .merged: self = .merged
    case .closed: self = .closed
    case .open: self = Self.openStatus(snapshot: snapshot, pullRequest: pullRequest)
    }
  }

  private static func openStatus(snapshot: RepoSnapshot, pullRequest: GitHubPullRequest) -> PRStatus {
    let target = pullRequest.baseRefName
    let checks = pullRequest.statusCheckRollup
    let failed = checks.filter { $0.outcome == .failed }.count
    let running = checks.filter { $0.outcome == .running }.count

    if snapshot.uncommittedCount > 0 || snapshot.pushState == .localAhead { return .commitAndPush }
    if snapshot.pushState == .outOfSync { return .waiting(reason: .outOfSync) }
    if pullRequest.mergeable == "CONFLICTING" { return .conflicts(target: target) }
    if failed > 0 { return .checksFailed(failed: failed, total: checks.count) }
    if running > 0 { return .checksRunning(done: checks.count - running, total: checks.count) }
    if pullRequest.isDraft { return .draft }
    if pullRequest.mergeable == "MERGEABLE", readyMergeStates.contains(pullRequest.mergeStateStatus) {
      return .ready
    }
    return .waiting(reason: waitingReason(pullRequest))
  }

  private static func waitingReason(_ pullRequest: GitHubPullRequest) -> WaitingReason {
    if pullRequest.mergeable == "UNKNOWN" || pullRequest.mergeStateStatus == "UNKNOWN" { return .gitHubChecking }
    if pullRequest.reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
    if pullRequest.reviewDecision == "REVIEW_REQUIRED" { return .reviewRequired }
    if pullRequest.mergeStateStatus == "BEHIND" { return .behind(target: pullRequest.baseRefName) }
    if pullRequest.mergeStateStatus == "BLOCKED" { return .blocked }
    return .notMergeable
  }

  /// The open same-repository pull request with the highest number; otherwise the highest merged or
  /// closed one, but only while its head is still `head` and nothing is uncommitted.
  public static func selectPullRequest(
    _ pullRequests: [GitHubPullRequest],
    head: String,
    uncommitted: Int
  ) -> GitHubPullRequest? {
    let sameRepository = pullRequests.filter { !$0.isCrossRepository }
    if let open = sameRepository.filter({ $0.state == .open }).max(by: { $0.number < $1.number }) {
      return open
    }
    guard let latest = sameRepository.max(by: { $0.number < $1.number }),
      latest.headRefOid == head, uncommitted == 0
    else { return nil }
    return latest
  }
}
