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

  static func pullRequestsCommand(_ branch: String = "b") -> [String] {
    ["gh", "pr", "list", "--head", branch, "--state", "all", "--limit", "20", "--json", prFields]
  }

  static func aheadCommand(_ target: String = "develop") -> [String] {
    ["git", "rev-list", "--count", "origin/\(target)..HEAD"]
  }

  static func isAncestorCommand(_ oid: String = otherHead) -> [String] {
    ["git", "merge-base", "--is-ancestor", oid, "HEAD"]
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
    case folder, appActivity, reload, turnStarts, turnEnds
  }

  @Test(arguments: KeyChange.allCases)
  func pollKeyChanges(_ change: KeyChange) async throws {
    let model = makeModel()
    let tab = try #require(model.chat.selectedTab)
    if change == .turnEnds {
      try await tab.enqueueUserMessage("hi")
      #expect(tab.isWorking)
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
    }

    #expect(model.pollKey != before)
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
}
