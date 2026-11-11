import CustomDump
import Foundation
import SlipstreamCore
import Testing

private func check(_ outcome: PullRequestCheck.Outcome) -> PullRequestCheck {
  PullRequestCheck(name: "check", link: nil, outcome: outcome)
}

private func checks(failed: Int = 0, running: Int = 0, done: Int = 0) -> [PullRequestCheck] {
  Array(repeating: check(.failed), count: failed)
    + Array(repeating: check(.running), count: running)
    + Array(repeating: check(.done), count: done)
}

private func pullRequest(
  number: Int = 1,
  state: GitHubPullRequest.State = .open,
  isDraft: Bool = false,
  headRefOid: String = "head",
  isCrossRepository: Bool = false,
  base: String = "develop",
  mergeable: String = "MERGEABLE",
  mergeState: String = "CLEAN",
  review: String? = nil,
  checks: [PullRequestCheck] = []
) -> GitHubPullRequest {
  GitHubPullRequest(
    number: number,
    url: URL(string: "https://github.com/o/r/pull/\(number)")!,
    state: state,
    isDraft: isDraft,
    headRefOid: headRefOid,
    isCrossRepository: isCrossRepository,
    baseRefName: base,
    mergeable: mergeable,
    mergeStateStatus: mergeState,
    reviewDecision: review,
    statusCheckRollup: checks
  )
}

private func snapshot(
  pr: GitHubPullRequest? = nil,
  uncommitted: Int = 0,
  push: PushState? = nil,
  ahead: Int? = nil
) -> RepoSnapshot {
  RepoSnapshot(
    branch: "b/x",
    uncommittedCount: uncommitted,
    defaultBranch: "develop",
    mergeMethod: "MERGE",
    pullRequest: pr,
    pushState: push,
    aheadOfTarget: ahead
  )
}

struct PRStatusTests {
  @Test(arguments: [
    ("cross-repo PRs are ignored", [pullRequest(number: 5, isCrossRepository: true)], 0, nil),
    ("highest open number wins", [pullRequest(number: 3), pullRequest(number: 7), pullRequest(number: 5)], 0, 7),
    ("open beats a newer merged PR", [pullRequest(number: 9, state: .merged), pullRequest(number: 4)], 0, 4),
    ("merged with matching head and clean tree", [pullRequest(number: 6, state: .merged)], 0, 6),
    ("closed with matching head and clean tree", [pullRequest(number: 6, state: .closed)], 0, 6),
    ("highest merged or closed number wins", [pullRequest(number: 2, state: .merged), pullRequest(number: 8, state: .closed)], 0, 8),
    ("merged with a moved head", [pullRequest(number: 6, state: .merged, headRefOid: "old")], 0, nil),
    ("merged with a dirty tree", [pullRequest(number: 6, state: .merged)], 1, nil),
    ("no PRs", [], 0, nil),
  ] as [(String, [GitHubPullRequest], Int, Int?)])
  func selection(_: String, prs: [GitHubPullRequest], uncommitted: Int, expected: Int?) {
    expectNoDifference(
      PRStatus.selectPullRequest(prs, head: "head", uncommitted: uncommitted)?.number,
      expected
    )
  }

  @Test(arguments: [
    (snapshot(uncommitted: 2, ahead: 0), PRStatus.noPRUncommitted),
    (snapshot(uncommitted: 0, ahead: 3), .noPRCommitted(ahead: 3, target: "develop")),
    (snapshot(uncommitted: 0, ahead: 0), .nothingToSubmit),
  ])
  func noPullRequest(snapshot: RepoSnapshot, expected: PRStatus) {
    expectNoDifference(PRStatus(snapshot: snapshot), expected)
  }

  @Test(arguments: [
    (snapshot(pr: pullRequest(), uncommitted: 1, push: .inSync), PRStatus.commitAndPush),
    (snapshot(pr: pullRequest(), push: .localAhead), .commitAndPush),
    (snapshot(pr: pullRequest(mergeable: "CONFLICTING"), uncommitted: 1, push: .inSync), .commitAndPush),
    (snapshot(pr: pullRequest(), push: .outOfSync), .waiting(reason: .outOfSync)),
    (snapshot(pr: pullRequest(base: "main", mergeable: "CONFLICTING", checks: checks(failed: 1)), push: .inSync), .conflicts(target: "main")),
    (snapshot(pr: pullRequest(mergeState: "BLOCKED", checks: checks(failed: 2, running: 1, done: 6)), push: .inSync), .checksFailed(failed: 2, total: 9)),
    (snapshot(pr: pullRequest(mergeState: "BLOCKED", checks: checks(running: 3, done: 6)), push: .inSync), .checksRunning(done: 6, total: 9)),
    (snapshot(pr: pullRequest(isDraft: true, checks: checks(done: 4)), push: .inSync), .draft),
    (snapshot(pr: pullRequest(isDraft: true, checks: checks(failed: 1, done: 3)), push: .inSync), .checksFailed(failed: 1, total: 4)),
    (snapshot(pr: pullRequest(mergeState: "CLEAN", checks: checks(done: 3)), push: .inSync), .ready),
    (snapshot(pr: pullRequest(mergeState: "HAS_HOOKS", checks: checks(done: 3)), push: .inSync), .ready),
    (snapshot(pr: pullRequest(mergeState: "UNSTABLE", checks: checks(done: 3)), push: .inSync), .ready),
    (snapshot(pr: pullRequest(mergeState: "CLEAN", checks: []), push: .inSync), .ready),
  ])
  func openPullRequest(snapshot: RepoSnapshot, expected: PRStatus) {
    expectNoDifference(PRStatus(snapshot: snapshot), expected)
  }

  @Test(arguments: [
    (pullRequest(mergeable: "UNKNOWN", mergeState: "CLEAN"), WaitingReason.gitHubChecking),
    (pullRequest(mergeable: "MERGEABLE", mergeState: "UNKNOWN"), .gitHubChecking),
    (pullRequest(mergeable: "UNKNOWN", mergeState: "UNKNOWN", review: "CHANGES_REQUESTED"), .gitHubChecking),
    (pullRequest(mergeState: "BLOCKED", review: "CHANGES_REQUESTED"), .changesRequested),
    (pullRequest(mergeState: "BLOCKED", review: "REVIEW_REQUIRED"), .reviewRequired),
    (pullRequest(base: "main", mergeState: "BEHIND"), .behind(target: "main")),
    (pullRequest(mergeState: "BLOCKED"), .blocked),
    (pullRequest(mergeState: "DIRTY_WEIRD"), .notMergeable),
  ])
  func waitingReason(pullRequest: GitHubPullRequest, expected: WaitingReason) {
    expectNoDifference(
      PRStatus(snapshot: snapshot(pr: pullRequest, push: .inSync)),
      .waiting(reason: expected)
    )
  }

  @Test(arguments: [
    (GitHubPullRequest.State.merged, PRStatus.merged),
    (.closed, .closed),
  ])
  func mergedAndClosed(state: GitHubPullRequest.State, expected: PRStatus) {
    expectNoDifference(PRStatus(snapshot: snapshot(pr: pullRequest(state: state))), expected)
  }
}
