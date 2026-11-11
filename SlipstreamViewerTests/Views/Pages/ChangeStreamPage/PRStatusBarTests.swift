import Clocks
import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

enum PRFixture {
  static let head = "1111111111111111111111111111111111111111"
  static let otherHead = "2222222222222222222222222222222222222222"
  static let prFields =
    "number,url,state,isDraft,headRefOid,isCrossRepository,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup"

  static let branchCommand = ["git", "rev-parse", "--abbrev-ref", "HEAD"]
  static let headCommand = ["git", "rev-parse", "HEAD"]
  static let originCommand = ["git", "remote", "get-url", "origin"]
  static let repositoryCommand = ["gh", "repo", "view", "--json", "isFork,defaultBranchRef,viewerDefaultMergeMethod"]
  static let statusCommand = ["git", "status", "--porcelain=v1"]
  static let upstreamCommand = ["git", "rev-parse", "--abbrev-ref", "@{upstream}"]
  static let unpushedCommand = ["git", "rev-list", "--count", "@{upstream}..HEAD"]
  static let fetchCommand = ["git", "fetch", "origin", "develop"]
  static let localBranchesCommand = ["git", "for-each-ref", "--format=%(refname:short)", "refs/heads"]
  static let remoteBranchesCommand = ["git", "ls-remote", "--heads", "origin"]
  static let actionsRuns = "https://github.com/playola-radio/slipstream-client-swift/actions/runs"

  static func pullRequestsCommand(_ branch: String = "b") -> [String] {
    ["gh", "pr", "list", "--head", branch, "--state", "all", "--limit", "20", "--json", prFields]
  }

  static func aheadCommand(_ target: String = "develop") -> [String] {
    ["git", "rev-list", "--count", "origin/\(target)..HEAD"]
  }

  static func isAncestorCommand(_ oid: String = otherHead) -> [String] {
    ["git", "merge-base", "--is-ancestor", oid, "HEAD"]
  }

  static func mergeCommand(_ flag: String = "--merge") -> [String] {
    ["gh", "pr", "merge", "https://github.com/o/r/pull/61", flag, "--match-head-commit", head]
  }

  static func runLogCommand(_ id: String) -> [String] {
    ["gh", "run", "view", id, "--repo", "playola-radio/slipstream-client-swift", "--log-failed"]
  }

  static func switchCommand(_ name: String) -> [String] {
    ["git", "switch", "-c", name, "origin/develop"]
  }

  static func repositoryJSON(isFork: Bool = false, mergeMethod: String = "MERGE") -> String {
    #"{"defaultBranchRef":{"name":"develop"},"isFork":\#(isFork),"viewerDefaultMergeMethod":"\#(mergeMethod)"}"#
  }

  static func checkRun(_ name: String, conclusion: String = "SUCCESS", link: String? = nil) -> String {
    let status = conclusion == "IN_PROGRESS" ? "IN_PROGRESS" : "COMPLETED"
    let conclusionJSON = conclusion == "IN_PROGRESS" ? "null" : #""\#(conclusion)""#
    let linkJSON = link.map { #""\#($0)""# } ?? "null"
    return
      #"{"__typename":"CheckRun","name":"\#(name)","detailsUrl":\#(linkJSON),"status":"\#(status)","conclusion":\#(conclusionJSON)}"#
  }

  static func pullRequestJSON(
    number: Int = 61, state: String = "OPEN", head: String = PRFixture.head, isDraft: Bool = false,
    mergeable: String = "MERGEABLE", mergeState: String = "CLEAN", reviewDecision: String? = nil,
    checks: [String] = [], base: String = "develop", isCrossRepository: Bool = false
  ) -> String {
    let review = reviewDecision.map { #""\#($0)""# } ?? "null"
    return #"""
      {"number":\#(number),"url":"https://github.com/o/r/pull/\#(number)","state":"\#(state)","isDraft":\#(isDraft),\#
      "headRefOid":"\#(head)","isCrossRepository":\#(isCrossRepository),"baseRefName":"\#(base)",\#
      "mergeable":"\#(mergeable)","mergeStateStatus":"\#(mergeState)","reviewDecision":\#(review),\#
      "statusCheckRollup":[\#(checks.joined(separator: ","))]}
      """#
  }

  static func pullRequest(_ json: String) -> GitHubPullRequest {
    try! JSONDecoder().decode(GitHubPullRequest.self, from: Data(json.utf8))
  }

  /// A clean branch `b` with no pull request, three commits ahead of `develop`.
  static func scriptRepository(_ repo: RepoCommandFake, branch: String = "b") {
    repo.set(branchCommand, stdout: "\(branch)\n")
    repo.set(headCommand, stdout: "\(head)\n")
    repo.set(originCommand, stdout: "git@github.com:o/r.git\n")
    repo.set(repositoryCommand, stdout: repositoryJSON())
    repo.set(statusCommand)
    repo.set(pullRequestsCommand(branch), stdout: "[]")
    repo.set(aheadCommand(), stdout: "3\n")
  }

  static func setPullRequest(_ repo: RepoCommandFake, _ json: String = pullRequestJSON(), branch: String = "b") {
    repo.set(pullRequestsCommand(branch), stdout: "[\(json)]")
  }

  static func checks(failed: Int = 0, running: Int = 0, passed: Int) -> [String] {
    (0..<failed).map { checkRun("failed \($0)", conclusion: "FAILURE") }
      + (0..<running).map { checkRun("running \($0)", conclusion: "IN_PROGRESS") }
      + (0..<passed).map { checkRun("passed \($0)") }
  }

  static func snapshot(
    uncommitted: Int = 0, pullRequest: GitHubPullRequest? = nil, push: PushState? = nil, ahead: Int? = 3
  ) -> RepoSnapshot {
    RepoSnapshot(
      head: head, branch: "b", uncommittedCount: uncommitted, defaultBranch: "develop", mergeMethod: "MERGE",
      pullRequest: pullRequest, pushState: push, aheadOfTarget: ahead)
  }
}

struct ReadCase: Sendable, CustomTestStringConvertible {
  enum Expected: Sendable {
    case notApplicable
    case snapshot(RepoSnapshot)
    case failure(details: [String])
  }

  var testDescription: String
  var script: @Sendable (RepoCommandFake) -> Void
  var expected: Expected

  static let all: [ReadCase] = [
    ReadCase(
      testDescription: "not a repository", script: { $0.set(PRFixture.branchCommand, ending: .exit(128)) },
      expected: .notApplicable),
    ReadCase(
      testDescription: "detached HEAD", script: { $0.set(PRFixture.branchCommand, stdout: "HEAD\n") },
      expected: .notApplicable),
    ReadCase(
      testDescription: "no origin", script: { $0.set(PRFixture.originCommand, ending: .exit(2)) },
      expected: .notApplicable),
    ReadCase(
      testDescription: "fork origin",
      script: { $0.set(PRFixture.repositoryCommand, stdout: PRFixture.repositoryJSON(isFork: true)) },
      expected: .notApplicable),
    ReadCase(
      testDescription: "no pull request", script: { _ in }, expected: .snapshot(PRFixture.snapshot())),
    ReadCase(
      testDescription: "uncommitted lines are counted",
      script: { $0.set(PRFixture.statusCommand, stdout: " M a.swift\n?? b.swift\n") },
      expected: .snapshot(PRFixture.snapshot(uncommitted: 2))),
    ReadCase(
      testDescription: "open pull request in sync",
      script: { $0.set(PRFixture.pullRequestsCommand(), stdout: "[\(PRFixture.pullRequestJSON())]") },
      expected: .snapshot(
        PRFixture.snapshot(pullRequest: PRFixture.pullRequest(PRFixture.pullRequestJSON()), push: .inSync, ahead: nil))),
    ReadCase(
      testDescription: "open pull request, local ahead",
      script: {
        $0.set(PRFixture.pullRequestsCommand(), stdout: "[\(PRFixture.pullRequestJSON(head: PRFixture.otherHead))]")
        $0.set(PRFixture.isAncestorCommand(), ending: .exit(0))
      },
      expected: .snapshot(
        PRFixture.snapshot(
          pullRequest: PRFixture.pullRequest(PRFixture.pullRequestJSON(head: PRFixture.otherHead)), push: .localAhead,
          ahead: nil))),
    ReadCase(
      testDescription: "open pull request, out of sync",
      script: {
        $0.set(PRFixture.pullRequestsCommand(), stdout: "[\(PRFixture.pullRequestJSON(head: PRFixture.otherHead))]")
        $0.set(PRFixture.isAncestorCommand(), ending: .exit(1))
      },
      expected: .snapshot(
        PRFixture.snapshot(
          pullRequest: PRFixture.pullRequest(PRFixture.pullRequestJSON(head: PRFixture.otherHead)), push: .outOfSync,
          ahead: nil))),
    ReadCase(
      testDescription: "gh signed out",
      script: {
        $0.set(
          PRFixture.pullRequestsCommand(), stderr: "To get started with GitHub CLI, please run:  gh auth login\n",
          ending: .exit(1))
      },
      expected: .failure(details: [
        """
        Folder: /w
        Command: gh pr list --head b --state all --limit 20 --json \(PRFixture.prFields)
        Ended: exit status 1

        stdout:
        (empty)

        stderr:
        To get started with GitHub CLI, please run:  gh auth login

        """
      ])),
    ReadCase(
      testDescription: "gh times out",
      script: { $0.set(PRFixture.repositoryCommand, ending: .timedOut(.seconds(20))) },
      expected: .failure(details: ["Ended: timed out after 20 s"])),
  ]
}

struct Display: Equatable, Sendable {
  var isRowContentShown = true
  var prNumberText: String?
  var statusIconName: String?
  var statusLabel = ""
  var statusDetail: String?
  var tone = PRStatusTone.muted
  var primaryButton: PRBarButton?
  var isContinueShown = false
  var isDetailsShown = false
}

extension Display {
  @MainActor init(_ model: PRStatusBarModel) {
    self.init(
      isRowContentShown: model.isRowContentShown, prNumberText: model.prNumberText,
      statusIconName: model.statusIconName, statusLabel: model.statusLabel, statusDetail: model.statusDetail,
      tone: model.tone, primaryButton: model.primaryButton, isContinueShown: model.isContinueShown,
      isDetailsShown: model.isDetailsShown)
  }
}

struct DisplayCase: Sendable, CustomTestStringConvertible {
  var testDescription: String
  var script: @Sendable (RepoCommandFake) -> Void
  var expected: Display

  static func open(_ description: String, _ json: String, _ expected: Display) -> DisplayCase {
    DisplayCase(testDescription: description, script: { PRFixture.setPullRequest($0, json) }, expected: expected)
  }

  static func waiting(_ description: String, _ json: String, reason: String) -> DisplayCase {
    open(
      description, json,
      Display(
        prNumberText: "#61", statusIconName: "Hourglass", statusLabel: "Waiting on GitHub", statusDetail: "· \(reason)"))
  }

  static let all: [DisplayCase] = [
    DisplayCase(
      testDescription: "checking", script: { $0.hold(PRFixture.statusCommand) },
      expected: Display(statusIconName: "LoaderCircle", statusLabel: "Checking for a pull request…")),
    DisplayCase(
      testDescription: "couldn't check",
      script: { $0.set(PRFixture.repositoryCommand, stderr: "gh: command not found\n", ending: .exit(127)) },
      expected: Display(
        statusIconName: "CircleAlert", statusLabel: "Couldn't check the pull request", tone: .danger,
        isDetailsShown: true)),
    DisplayCase(
      testDescription: "not applicable", script: { $0.set(PRFixture.branchCommand, ending: .exit(128)) },
      expected: Display(isRowContentShown: false)),
    DisplayCase(
      testDescription: "nothing to submit", script: { $0.set(PRFixture.aheadCommand(), stdout: "0\n") },
      expected: Display(isRowContentShown: false)),
    DisplayCase(
      testDescription: "no PR, uncommitted", script: { $0.set(PRFixture.statusCommand, stdout: " M a.swift\n") },
      expected: Display(statusLabel: "Uncommitted changes", tone: .neutral, primaryButton: .createPR)),
    DisplayCase(
      testDescription: "no PR, committed", script: { _ in },
      expected: Display(
        statusLabel: "Ready for a pull request", statusDetail: "· 3 commits ahead of develop", tone: .neutral,
        primaryButton: .createPR)),
    DisplayCase(
      testDescription: "no PR, one commit", script: { $0.set(PRFixture.aheadCommand(), stdout: "1\n") },
      expected: Display(
        statusLabel: "Ready for a pull request", statusDetail: "· 1 commit ahead of develop", tone: .neutral,
        primaryButton: .createPR)),
    DisplayCase(
      testDescription: "open, uncommitted",
      script: {
        PRFixture.setPullRequest($0)
        $0.set(PRFixture.statusCommand, stdout: " M a.swift\n")
      },
      expected: Display(
        prNumberText: "#61", statusLabel: "Uncommitted changes", tone: .neutral, primaryButton: .commitAndPush)),
    DisplayCase(
      testDescription: "open, unpushed",
      script: {
        PRFixture.setPullRequest($0, PRFixture.pullRequestJSON(head: PRFixture.otherHead))
        $0.set(PRFixture.isAncestorCommand(), ending: .exit(0))
      },
      expected: Display(
        prNumberText: "#61", statusLabel: "Uncommitted changes", tone: .neutral, primaryButton: .commitAndPush)),
    open(
      "open, conflicts", PRFixture.pullRequestJSON(mergeable: "CONFLICTING", mergeState: "DIRTY"),
      Display(
        prNumberText: "#61", statusIconName: "TriangleAlert", statusLabel: "Merge conflicts",
        statusDetail: "with develop", tone: .warning, primaryButton: .resolveConflicts)),
    open(
      "open, checks failed", PRFixture.pullRequestJSON(checks: PRFixture.checks(failed: 2, passed: 7)),
      Display(
        prNumberText: "#61", statusIconName: "CircleX", statusLabel: "Checks failed", statusDetail: "· 2 of 9 failed",
        tone: .danger, primaryButton: .fixErrors)),
    open(
      "open, checks running", PRFixture.pullRequestJSON(checks: PRFixture.checks(running: 3, passed: 6)),
      Display(
        prNumberText: "#61", statusIconName: "LoaderCircle", statusLabel: "Checks running",
        statusDetail: "· 6 of 9 done")),
    open(
      "open, ready", PRFixture.pullRequestJSON(),
      Display(
        prNumberText: "#61", statusIconName: "CircleCheck", statusLabel: "Ready to merge", tone: .success,
        primaryButton: .merge)),
    open(
      "open, draft", PRFixture.pullRequestJSON(isDraft: true),
      Display(
        prNumberText: "#61", statusIconName: "GitPullRequestDraft", statusLabel: "Draft",
        statusDetail: "· all checks passed")),
    waiting(
      "waiting, GitHub checking", PRFixture.pullRequestJSON(mergeable: "UNKNOWN", mergeState: "UNKNOWN"),
      reason: "GitHub is still checking"),
    waiting(
      "waiting, changes requested",
      PRFixture.pullRequestJSON(mergeState: "BLOCKED", reviewDecision: "CHANGES_REQUESTED"),
      reason: "changes requested"),
    waiting(
      "waiting, review required", PRFixture.pullRequestJSON(mergeState: "BLOCKED", reviewDecision: "REVIEW_REQUIRED"),
      reason: "review required"),
    waiting("waiting, behind", PRFixture.pullRequestJSON(mergeState: "BEHIND"), reason: "behind develop"),
    waiting("waiting, blocked", PRFixture.pullRequestJSON(mergeState: "BLOCKED"), reason: "blocked by branch rules"),
    waiting("waiting, not mergeable", PRFixture.pullRequestJSON(mergeState: "DIRTY"), reason: "not mergeable yet"),
    DisplayCase(
      testDescription: "waiting, out of sync",
      script: {
        PRFixture.setPullRequest($0, PRFixture.pullRequestJSON(head: PRFixture.otherHead))
        $0.set(PRFixture.isAncestorCommand(), ending: .exit(1))
      },
      expected: Display(
        prNumberText: "#61", statusIconName: "Hourglass", statusLabel: "Waiting on GitHub",
        statusDetail: "· branch is out of sync with the PR")),
    open(
      "merged", PRFixture.pullRequestJSON(state: "MERGED"),
      Display(
        prNumberText: "#61", statusIconName: "GitMerge", statusLabel: "Merged", tone: .merged, isContinueShown: true)),
    open(
      "closed", PRFixture.pullRequestJSON(state: "CLOSED"),
      Display(
        prNumberText: "#61", statusIconName: "GitPullRequestClosed", statusLabel: "Closed", primaryButton: .createPR)),
  ]
}

struct UpstreamCase: Sendable, CustomTestStringConvertible {
  var testDescription: String
  var script: @Sendable (RepoCommandFake) -> Void
  var expected: PRInstructions.Upstream

  static let all: [UpstreamCase] = [
    UpstreamCase(
      testDescription: "no upstream",
      script: {
        $0.set(PRFixture.upstreamCommand, stderr: "fatal: no upstream configured for branch 'b'\n", ending: .exit(128))
      },
      expected: .none),
    UpstreamCase(
      testDescription: "upstream in sync",
      script: {
        $0.set(PRFixture.upstreamCommand, stdout: "origin/b\n")
        $0.set(PRFixture.unpushedCommand, stdout: "0\n")
      },
      expected: .inSync("origin/b")),
    UpstreamCase(
      testDescription: "unpushed commits",
      script: {
        $0.set(PRFixture.upstreamCommand, stdout: "origin/b\n")
        $0.set(PRFixture.unpushedCommand, stdout: "2\n")
      },
      expected: .unpushed(2)),
  ]
}

struct MessageCase: Sendable, CustomTestStringConvertible {
  var testDescription: String
  var script: @Sendable (RepoCommandFake) -> Void
  var button: PRBarButton
  var message: String

  static let all: [MessageCase] = [
    MessageCase(
      testDescription: "commit and push",
      script: {
        PRFixture.setPullRequest($0)
        $0.set(PRFixture.statusCommand, stdout: " M a.swift\n")
      },
      button: .commitAndPush, message: "Commit and push all changes"),
    MessageCase(
      testDescription: "resolve conflicts",
      script: {
        PRFixture.setPullRequest($0, PRFixture.pullRequestJSON(mergeable: "CONFLICTING", base: "main"))
      },
      button: .resolveConflicts, message: PRInstructions.resolveConflictsMessage(target: "main")),
  ]
}

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct PRStatusBarTests {
  let agent = AgentFake()
  let link = ChatLinkFake()
  let repo = RepoCommandFake()
  let clock = TestClock()
  let copied = LockIsolated<[String]>([])
  let written = LockIsolated<[String: String]>([:])
  let writeError = LockIsolated<(any Error)?>(nil)

  func makeModel(folder: String? = "/w") -> PRStatusBarModel {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.agentEnvironment = agent.environmentClient
      $0.agentProcess = agent.processClient
      $0.transcripts = agent.transcriptClient
      $0.chatLink = link.client
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.date = DateGenerator { Date(timeIntervalSince1970: 1_760_000_000) }
      $0.timeZone = TimeZone(identifier: "UTC")!
      $0.repoCommand = repo.client
      $0.pasteboard = PasteboardClient(copy: { [copied] text in copied.withValue { $0.append(text) } })
      $0.attachments.write = { [written, writeError] name, contents in
        if let error = writeError.value { throw error }
        written.withValue { $0[name] = contents }
        return URL(fileURLWithPath: "/attachments/U/\(name)")
      }
    } operation: {
      @Shared(.chatTabs) var stored
      $stored.withLock { $0 = [] }
      let chat = ChatPageModel()
      chat.workspaceChanged(folder: folder, emptyText: nil)
      return PRStatusBarModel(chat: chat)
    }
  }

  func reads(_ folder: String = "/w") -> Int {
    repo.calls(PRFixture.branchCommand).filter { $0.folder == folder }.count
  }

  // MARK: - Reading

  @Test(arguments: ReadCase.all)
  func readsSnapshot(_ readCase: ReadCase) async {
    PRFixture.scriptRepository(repo)
    readCase.script(repo)
    let model = makeModel()

    let poll = Task { await model.pollTask() }
    await Task.megaYield()

    switch readCase.expected {
    case .notApplicable:
      expectNoDifference(model.snapshot, nil)
      expectNoDifference(model.checkFailure, nil)
      #expect(!model.isCheckingShown)
    case .snapshot(let snapshot):
      expectNoDifference(model.snapshot, snapshot)
      expectNoDifference(model.status, PRStatus(snapshot: snapshot))
      expectNoDifference(model.checkFailure, nil)
    case .failure(let details):
      expectNoDifference(model.snapshot, nil)
      expectNoDifference(model.checkFailure?.title, "Couldn't check the pull request")
      for detail in details {
        #expect(model.checkFailure?.details.contains(detail) == true, "\(model.checkFailure?.details ?? "nil")")
      }
    }
    poll.cancel()
    await poll.value
  }

  @Test func readsUseTheNamedTimeoutsInTheFolder() async {
    PRFixture.scriptRepository(repo)
    let model = makeModel()

    let poll = Task { await model.pollTask() }
    await Task.megaYield()

    expectNoDifference(
      repo.calls,
      [
        .init(arguments: PRFixture.branchCommand, folder: "/w", timeout: .seconds(10)),
        .init(arguments: PRFixture.headCommand, folder: "/w", timeout: .seconds(10)),
        .init(arguments: PRFixture.originCommand, folder: "/w", timeout: .seconds(10)),
        .init(arguments: PRFixture.repositoryCommand, folder: "/w", timeout: .seconds(20)),
        .init(arguments: PRFixture.statusCommand, folder: "/w", timeout: .seconds(10)),
        .init(arguments: PRFixture.pullRequestsCommand(), folder: "/w", timeout: .seconds(20)),
        .init(arguments: PRFixture.aheadCommand(), folder: "/w", timeout: .seconds(10)),
      ])
    poll.cancel()
    await poll.value
  }

  // MARK: - Ownership

  func load(_ model: PRStatusBarModel) async {
    let poll = Task { await model.pollTask() }
    await Task.megaYield()
    poll.cancel()
    await poll.value
  }

  enum Interruption: CaseIterable, Sendable {
    case switchAwayAndBack, archived
  }

  @Test(arguments: Interruption.allCases)
  func cancelledPollNeverPublishes(_ interruption: Interruption) async {
    PRFixture.scriptRepository(repo)
    repo.set(PRFixture.statusCommand, stdout: " M stale.swift\n")
    repo.hold(PRFixture.statusCommand)
    let model = makeModel()
    let first = Task { await model.pollTask() }
    await Task.megaYield()
    repo.set(PRFixture.statusCommand)

    switch interruption {
    case .switchAwayAndBack:
      model.chat.workspaceChanged(folder: "/other", emptyText: nil)
      first.cancel()
      let second = Task { await model.pollTask() }
      await Task.megaYield()
      second.cancel()
      await second.value
      model.chat.workspaceChanged(folder: "/w", emptyText: nil)
      let third = Task { await model.pollTask() }
      await Task.megaYield()
      repo.release()
      await first.value
      expectNoDifference(model.snapshot, PRFixture.snapshot())
      third.cancel()
      await third.value
    case .archived:
      model.chat.workspaceChanged(folder: nil, emptyText: nil)
      first.cancel()
      repo.release()
      await first.value
      model.chat.workspaceChanged(folder: "/w", emptyText: nil)
      expectNoDifference(model.snapshot, nil)
      #expect(model.isCheckingShown)
    }
  }

  enum KeyChange: CaseIterable, Sendable {
    case folder, appActivity, reload, turnStarts, turnEnds, operationStarts, operationEnds
  }

  @Test(arguments: KeyChange.allCases)
  func pollKeyChanges(_ change: KeyChange) async throws {
    let model = makeModel()
    let tab = try #require(model.chat.selectedTab)
    var merge: Task<Void, Never>?
    switch change {
    case .turnEnds:
      try await tab.enqueueUserMessage("hi")
      #expect(tab.isWorking)
    case .operationStarts, .operationEnds:
      PRFixture.scriptRepository(repo)
      PRFixture.setPullRequest(repo)
      repo.set(PRFixture.mergeCommand())
      repo.hold(PRFixture.mergeCommand())
      await load(model)
      if change == .operationEnds {
        merge = Task { await model.primaryButtonTapped() }
        await Task.megaYield()
      }
    default: break
    }
    let before = model.pollKey

    switch change {
    case .folder: model.chat.workspaceChanged(folder: "/other", emptyText: nil)
    case .appActivity: model.chat.appActivityChanged(isActive: false)
    case .reload: model.reloadRequested()
    case .turnStarts: try await tab.enqueueUserMessage("hi")
    case .turnEnds:
      agent.sendLine(Line.result())
      await Task.megaYield()
    case .operationStarts:
      merge = Task { await model.primaryButtonTapped() }
      await Task.megaYield()
    case .operationEnds:
      repo.release()
      await merge?.value
    }

    #expect(model.pollKey != before)
    repo.release()
    await merge?.value
  }

  @Test func readFinishingDuringMergeKeepsMerging() async {
    PRFixture.scriptRepository(repo)
    PRFixture.setPullRequest(repo)
    repo.set(PRFixture.mergeCommand())
    let model = makeModel()
    await load(model)
    repo.set(PRFixture.statusCommand, stdout: " M stale.swift\n")
    repo.hold(PRFixture.statusCommand)
    let poll = Task { await model.pollTask() }
    await Task.megaYield()

    repo.hold(PRFixture.mergeCommand())
    let merge = Task { await model.primaryButtonTapped() }
    await Task.megaYield()
    poll.cancel()
    repo.release(PRFixture.statusCommand)
    await poll.value

    expectNoDifference(model.statusLabel, "Merging…")
    expectNoDifference(model.status, .ready)
    repo.release()
    await merge.value
  }

  @Test func pollWaitsThirtySecondsAfterCompletion() async {
    PRFixture.scriptRepository(repo)
    let model = makeModel()

    let poll = Task { await model.pollTask() }
    await Task.megaYield()
    #expect(reads() == 1)
    await clock.advance(by: .seconds(29))
    await Task.megaYield()
    #expect(reads() == 1)
    await clock.advance(by: .seconds(1))
    await Task.megaYield()
    #expect(reads() == 2)

    poll.cancel()
    await poll.value
  }

  @Test func inactiveDoesNotRead() async {
    PRFixture.scriptRepository(repo)
    let model = makeModel()
    model.chat.appActivityChanged(isActive: false)

    await model.pollTask()
    await clock.advance(by: .seconds(300))
    await Task.megaYield()
    #expect(reads() == 0)

    model.chat.appActivityChanged(isActive: true)
    let poll = Task { await model.pollTask() }
    await Task.megaYield()
    await clock.advance(by: .seconds(29))
    await Task.megaYield()
    #expect(reads() == 1)

    poll.cancel()
    await poll.value
  }

  @Test func checkingShowsUntilFirstResult() async {
    PRFixture.scriptRepository(repo)
    repo.hold(PRFixture.statusCommand)
    let model = makeModel()

    let poll = Task { await model.pollTask() }
    await Task.megaYield()
    #expect(model.isCheckingShown)

    repo.release()
    await Task.megaYield()
    #expect(!model.isCheckingShown)
    expectNoDifference(model.status, .noPRCommitted(ahead: 3, target: "develop"))

    repo.hold(PRFixture.statusCommand)
    await clock.advance(by: .seconds(30))
    await Task.megaYield()
    #expect(reads() == 2)
    #expect(!model.isCheckingShown)
    expectNoDifference(model.status, .noPRCommitted(ahead: 3, target: "develop"))

    repo.release()
    poll.cancel()
    await poll.value
  }

  @Test func failureReplacedBySuccess() async {
    PRFixture.scriptRepository(repo)
    repo.set(PRFixture.repositoryCommand, stderr: "error connecting to api.github.com\n", ending: .exit(1))
    let model = makeModel()

    let poll = Task { await model.pollTask() }
    await Task.megaYield()
    expectNoDifference(model.checkFailure?.title, "Couldn't check the pull request")

    repo.set(PRFixture.repositoryCommand, stdout: PRFixture.repositoryJSON())
    await clock.advance(by: .seconds(30))
    await Task.megaYield()
    expectNoDifference(model.checkFailure, nil)
    expectNoDifference(model.status, .noPRCommitted(ahead: 3, target: "develop"))

    poll.cancel()
    await poll.value
  }

  // MARK: - Display

  @Test(arguments: DisplayCase.all)
  func displaysState(_ displayCase: DisplayCase) async {
    PRFixture.scriptRepository(repo)
    displayCase.script(repo)
    let model = makeModel()

    let poll = Task { await model.pollTask() }
    await Task.megaYield()
    expectNoDifference(Display(model), displayCase.expected)

    repo.release()
    poll.cancel()
    await poll.value
  }

  @Test func pullRequestChipOpensThePullRequest() async {
    PRFixture.scriptRepository(repo)
    PRFixture.setPullRequest(repo)
    let model = makeModel()
    await load(model)

    expectNoDifference(model.pullRequestURL, URL(string: "https://github.com/o/r/pull/61"))
  }

  @Test(arguments: [false, true])
  func archiveShownOnlyWhenArchivable(_ isArchivable: Bool) async {
    PRFixture.scriptRepository(repo)
    PRFixture.setPullRequest(repo, PRFixture.pullRequestJSON(state: "MERGED"))
    let model = makeModel()
    model.isArchivable = { isArchivable }
    await load(model)

    #expect(model.isArchiveShown == isArchivable)
  }

  @Test func archiveTappedAsksTheOwner() {
    let model = makeModel()
    var archiveCount = 0
    model.onArchive = { archiveCount += 1 }

    model.archiveTapped()

    #expect(archiveCount == 1)
  }

  @Test(arguments: [(PRBarButton.createPR, false), (PRBarButton.merge, true)])
  func agentButtonsWaitForAWorkingChat(_ button: PRBarButton, _ isEnabled: Bool) async throws {
    PRFixture.scriptRepository(repo)
    if button == .merge { PRFixture.setPullRequest(repo) }
    let model = makeModel()
    await load(model)
    #expect(model.isPrimaryButtonEnabled)

    try await #require(model.chat.selectedTab).enqueueUserMessage("hi")

    expectNoDifference(model.primaryButton, button)
    #expect(model.isPrimaryButtonEnabled == isEnabled)
  }

  @Test func detailsCopyAndDismiss() async {
    PRFixture.scriptRepository(repo)
    PRFixture.setPullRequest(repo)
    repo.set(PRFixture.mergeCommand(), stderr: "Pull request is not mergeable\n", ending: .exit(1))
    let model = makeModel()
    await load(model)
    await model.primaryButtonTapped()
    let failure = model.failure

    model.detailsTapped()
    #expect(model.isDetailsPresented)
    model.copyTapped()
    expectNoDifference(copied.value, ["Merge failed\n\n" + (failure?.details ?? "")])
    model.detailsDismissed()

    #expect(!model.isDetailsPresented)
    expectNoDifference(model.failure, nil)
    expectNoDifference(model.statusLabel, "Ready to merge")
  }

  @Test func actionFailureClearedByWorkspaceChange() async {
    PRFixture.scriptRepository(repo)
    PRFixture.setPullRequest(repo)
    repo.set(PRFixture.mergeCommand(), ending: .exit(1))
    let model = makeModel()
    await load(model)
    await model.primaryButtonTapped()
    #expect(model.failure != nil)

    model.chat.workspaceChanged(folder: "/other", emptyText: nil)
    expectNoDifference(model.failure, nil)
    await load(model)
    model.chat.workspaceChanged(folder: "/w", emptyText: nil)

    expectNoDifference(model.failure, nil)
  }

  // MARK: - Agent buttons

  @Test(arguments: UpstreamCase.all)
  func createPRWritesClickTimeFacts(_ upstreamCase: UpstreamCase) async throws {
    PRFixture.scriptRepository(repo)
    let model = makeModel()
    await load(model)
    let tab = try #require(model.chat.selectedTab)
    repo.set(PRFixture.statusCommand, stdout: " M a.swift\n M b.swift\n")
    upstreamCase.script(repo)

    await model.primaryButtonTapped()

    expectNoDifference(
      written.value,
      [
        "PR instructions.md": PRInstructions.createPR(
          uncommitted: 2, branch: "b", target: "develop", upstream: upstreamCase.expected)
      ])
    expectNoDifference(
      tab.projection.items.map(\.kind),
      [.userMessage("Create a PR @\u{27E6}PR instructions.md\u{27E7}(/attachments/U/PR%20instructions.md)")])
    expectNoDifference(model.failure, nil)
  }

  @Test func attachmentWriteFailureSendsNothing() async throws {
    struct DiskFull: Error, CustomStringConvertible {
      var description: String { "The disk is full." }
    }
    PRFixture.scriptRepository(repo)
    repo.set(PRFixture.upstreamCommand, ending: .exit(128))
    let model = makeModel()
    await load(model)
    let tab = try #require(model.chat.selectedTab)
    writeError.setValue(DiskFull())

    await model.primaryButtonTapped()

    expectNoDifference(tab.projection.items, [])
    expectNoDifference(
      model.failure,
      PRBarFailure(
        title: "Couldn't send Create PR", details: "Folder: /w\nCouldn't write PR instructions.md: The disk is full."))
    expectNoDifference(
      Display(model),
      Display(
        statusIconName: "CircleAlert", statusLabel: "Couldn't send Create PR", tone: .danger,
        primaryButton: .createPR, isDetailsShown: true))

    writeError.setValue(nil)
    repo.hold(PRFixture.statusCommand)
    let retry = Task { await model.primaryButtonTapped() }
    await Task.megaYield()
    expectNoDifference(model.failure, nil)
    repo.release()
    await retry.value
  }

  @Test func closedTabSendsNothing() async throws {
    PRFixture.scriptRepository(repo)
    repo.set(PRFixture.upstreamCommand, ending: .exit(128))
    let model = makeModel()
    await load(model)
    let tab = try #require(model.chat.selectedTab)
    repo.hold(PRFixture.statusCommand)

    let send = Task { await model.primaryButtonTapped() }
    await Task.megaYield()
    #expect(!model.isPrimaryButtonEnabled)
    await model.chat.closeTabTapped(tab.id)
    repo.release()
    await send.value

    expectNoDifference(tab.projection.items, [])
    expectNoDifference(model.chat.selectedTab?.projection.items, [])
    expectNoDifference(
      model.failure,
      PRBarFailure(title: "Couldn't send Create PR", details: "Folder: /w\nThe chat tab was closed, so nothing was sent."))
    #expect(model.isPrimaryButtonEnabled)
  }

  @Test func noChatTabOpensOne() async throws {
    PRFixture.scriptRepository(repo)
    PRFixture.setPullRequest(repo)
    repo.set(PRFixture.statusCommand, stdout: " M a.swift\n")
    let model = makeModel()
    await load(model)
    model.chat.tabs.removeAll()
    #expect(model.chat.selectedTab == nil)

    await model.primaryButtonTapped()

    let tab = try #require(model.chat.selectedTab)
    expectNoDifference(tab.projection.items.map(\.kind), [.userMessage("Commit and push all changes")])
  }

  @Test(arguments: MessageCase.all)
  func plainMessagesHaveNoAttachment(_ messageCase: MessageCase) async throws {
    PRFixture.scriptRepository(repo)
    messageCase.script(repo)
    let model = makeModel()
    await load(model)
    let tab = try #require(model.chat.selectedTab)
    expectNoDifference(model.primaryButton, messageCase.button)

    await model.primaryButtonTapped()

    expectNoDifference(tab.projection.items.map(\.kind), [.userMessage(messageCase.message)])
    expectNoDifference(written.value, [:])
  }

  @Test func fixErrorsAttachesEachRunsLogOnce() async throws {
    let json = PRFixture.pullRequestJSON(checks: [
      PRFixture.checkRun("lint", conclusion: "FAILURE", link: "\(PRFixture.actionsRuns)/1/job/11"),
      PRFixture.checkRun("test", conclusion: "FAILURE", link: "\(PRFixture.actionsRuns)/1/job/12"),
      PRFixture.checkRun("build", conclusion: "FAILURE", link: "\(PRFixture.actionsRuns)/2/job/21"),
      PRFixture.checkRun("CodeRabbit", conclusion: "FAILURE", link: "https://coderabbit.ai/review/1"),
      PRFixture.checkRun("docs", link: "\(PRFixture.actionsRuns)/3/job/31"),
    ])
    PRFixture.scriptRepository(repo)
    PRFixture.setPullRequest(repo, json)
    repo.set(PRFixture.runLogCommand("1"), stdout: "lint failed\n")
    repo.set(PRFixture.runLogCommand("2"), stderr: "HTTP 502\n", ending: .exit(1))
    let model = makeModel()
    await load(model)
    let tab = try #require(model.chat.selectedTab)

    await model.primaryButtonTapped()

    expectNoDifference(
      repo.calls.filter { $0.arguments.starts(with: ["gh", "run"]) },
      [
        .init(arguments: PRFixture.runLogCommand("1"), folder: "/w", timeout: .seconds(60)),
        .init(arguments: PRFixture.runLogCommand("2"), folder: "/w", timeout: .seconds(60)),
      ])
    let repository = "playola-radio/slipstream-client-swift"
    expectNoDifference(
      written.value,
      [
        "Fix errors instructions.md": PRInstructions.fixErrors(
          pullRequest: PRFixture.pullRequest(json), branch: "b",
          logs: [
            ActionsRun(repository: repository, id: "1"): "lint failed\n",
            ActionsRun(repository: repository, id: "2"): """
            Folder: /w
            Command: gh run view 2 --repo \(repository) --log-failed
            Ended: exit status 1

            stdout:
            (empty)

            stderr:
            HTTP 502

            """,
          ])
      ])
    expectNoDifference(
      tab.projection.items.map(\.kind),
      [
        .userMessage(
          "Fix the failing CI actions. I've attached the failure logs. "
            + "@\u{27E6}Fix errors instructions.md\u{27E7}(/attachments/U/Fix%20errors%20instructions.md)")
      ])
    expectNoDifference(model.failure, nil)
  }

  // MARK: - Merge

  @Test(arguments: [("MERGE", "--merge"), ("SQUASH", "--squash"), ("REBASE", "--rebase")])
  func mergeRunsGitHubWithTheShownHead(_ method: String, _ flag: String) async {
    PRFixture.scriptRepository(repo)
    repo.set(PRFixture.repositoryCommand, stdout: PRFixture.repositoryJSON(mergeMethod: method))
    PRFixture.setPullRequest(repo)
    let command = PRFixture.mergeCommand(flag)
    repo.set(command)
    repo.hold(command)
    let model = makeModel()
    await load(model)

    let merge = Task { await model.primaryButtonTapped() }
    await Task.megaYield()
    expectNoDifference(
      Display(model),
      Display(prNumberText: "#61", statusIconName: "LoaderCircle", statusLabel: "Merging…", primaryButton: .merge))
    #expect(!model.isPrimaryButtonEnabled)
    await model.pollTask()
    #expect(reads() == 1)
    repo.release()
    await merge.value

    expectNoDifference(repo.calls(command), [.init(arguments: command, folder: "/w", timeout: .seconds(60))])
    expectNoDifference(model.failure, nil)
    #expect(model.isPrimaryButtonEnabled)
  }

  @Test func mergeFailureShowsOutput() async {
    PRFixture.scriptRepository(repo)
    PRFixture.setPullRequest(repo)
    repo.set(
      PRFixture.mergeCommand(), stderr: "X Pull request o/r#61 is not mergeable: the base branch policy prohibits it.\n",
      ending: .exit(1))
    let model = makeModel()
    await load(model)

    await model.primaryButtonTapped()

    expectNoDifference(model.failure?.title, "Merge failed")
    #expect(model.failure?.details.contains("the base branch policy prohibits it.") == true)
    expectNoDifference(
      Display(model),
      Display(
        prNumberText: "#61", statusIconName: "CircleAlert", statusLabel: "Merge failed", tone: .danger,
        primaryButton: .merge, isDetailsShown: true))
    #expect(model.isPrimaryButtonEnabled)
  }

  // MARK: - Continue

  func scriptMerged(branch: String = "b", local: String, remote: String) {
    PRFixture.scriptRepository(repo, branch: branch)
    PRFixture.setPullRequest(repo, PRFixture.pullRequestJSON(state: "MERGED"), branch: branch)
    repo.set(PRFixture.fetchCommand)
    repo.set(PRFixture.localBranchesCommand, stdout: local)
    repo.set(PRFixture.remoteBranchesCommand, stdout: remote)
  }

  @Test func continueStartsTheNextFreeBranch() async {
    scriptMerged(local: "b\nmain\n", remote: "\(PRFixture.head)\trefs/heads/b\n\(PRFixture.head)\trefs/heads/b-2\n")
    repo.set(PRFixture.switchCommand("b-3"))
    let model = makeModel()
    await load(model)
    let readCalls = repo.calls.count

    await model.continueTapped()

    expectNoDifference(
      Array(repo.calls.dropFirst(readCalls)),
      [
        .init(arguments: PRFixture.fetchCommand, folder: "/w", timeout: .seconds(60)),
        .init(arguments: PRFixture.localBranchesCommand, folder: "/w", timeout: .seconds(10)),
        .init(arguments: PRFixture.remoteBranchesCommand, folder: "/w", timeout: .seconds(10)),
        .init(arguments: PRFixture.switchCommand("b-3"), folder: "/w", timeout: .seconds(10)),
      ])
    expectNoDifference(model.failure, nil)
  }

  @Test(arguments: [PRFixture.fetchCommand, PRFixture.switchCommand("b-2")])
  func continueFailureShowsDetails(_ failing: [String]) async {
    scriptMerged(local: "b\n", remote: "")
    repo.set(PRFixture.switchCommand("b-2"))
    repo.set(failing, stderr: "fatal: something went wrong\n", ending: .exit(128))
    let model = makeModel()
    await load(model)

    await model.continueTapped()

    expectNoDifference(model.failure?.title, "Couldn't start a new branch")
    #expect(model.failure?.details.contains("fatal: something went wrong") == true)
    #expect(model.isContinueShown)
  }

  @Test func branchWithAwkwardCharacters() async {
    let branch = "feature/a b#(1)"
    scriptMerged(branch: branch, local: "\(branch)\n", remote: "")
    repo.set(PRFixture.switchCommand("\(branch)-2"))
    let model = makeModel()
    await load(model)
    expectNoDifference(model.status, .merged)

    await model.continueTapped()

    #expect(repo.calls(PRFixture.pullRequestsCommand(branch)).count == 1)
    #expect(repo.calls(PRFixture.switchCommand("\(branch)-2")).count == 1)
    expectNoDifference(model.failure, nil)
  }
}
