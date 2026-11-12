import CustomDump
import Foundation
import SlipstreamCore
import Testing

private func createPRTemplate(upstreamLine: String, uncommitted: Int = 2) -> String {
  """
  The user likes the current state of the code.

  There are \(uncommitted) uncommitted changes.
  The current branch is b/x.
  The target branch is origin/develop.

  \(upstreamLine)
  The user requested a PR.

  Follow these steps to create a PR:

  - If you have any skills related to creating PRs, invoke them now. Instructions there should take precedence over these instructions.
  - Run `git diff`, `git diff --cached`, and `git status --short` to review unstaged, staged, and untracked changes
  - If there are uncommitted changes, commit them. Follow any instructions the user gave you about writing commit messages.
  - Push to origin.
  - Run `git diff origin/develop...HEAD` to review the PR diff
  - Use `gh pr create --repo playola-radio/slipstream-client-swift --base develop` to create a PR onto the target branch. Keep the title under 80 characters. Keep the description under five sentences, unless the user instructed you otherwise. Describe not just changes made in this session but ALL changes in the workspace diff.

  If any of these steps fail, ask the user for help.
  """
}

private func pullRequest(checks: [PullRequestCheck]) -> GitHubPullRequest {
  GitHubPullRequest(
    number: 81,
    url: URL(string: "https://github.com/o/r/pull/81")!,
    state: .open,
    isDraft: false,
    headRefOid: "abc",
    isCrossRepository: false,
    baseRefName: "develop",
    mergeable: "MERGEABLE",
    mergeStateStatus: "BLOCKED",
    reviewDecision: nil,
    statusCheckRollup: checks
  )
}

private let testRun = ActionsRun(repository: "o/r", id: "111")
private let lintRun = ActionsRun(repository: "o/r", id: "222")

struct PRInstructionsTests {
  @Test(arguments: [
    (PRInstructions.Upstream.none, "There is no upstream branch yet."),
    (.inSync("origin/b/x"), "The upstream branch is origin/b/x."),
    (.unpushed(3), "There are 3 unpushed commits."),
  ])
  func createPRMatchesTemplate(upstream: PRInstructions.Upstream, line: String) {
    expectNoDifference(
      PRInstructions.createPR(
        uncommitted: 2, branch: "b/x", target: "develop", repository: "playola-radio/slipstream-client-swift",
        upstream: upstream),
      createPRTemplate(upstreamLine: line)
    )
  }

  @Test func createPRWithCommittedChangesDoesNotRequireACommit() {
    let text = PRInstructions.createPR(
      uncommitted: 0, branch: "b/x", target: "develop", repository: "playola-radio/slipstream-client-swift",
      upstream: .unpushed(2))

    expectNoDifference(text, createPRTemplate(upstreamLine: "There are 2 unpushed commits.", uncommitted: 0))
  }

  @Test func fixErrorsListsChecksAndLogs() throws {
    let log = (1...1000).map { "line \($0)" }.joined(separator: "\n")
    let text = PRInstructions.fixErrors(
      pullRequest: pullRequest(checks: [
        PullRequestCheck(name: "test", link: URL(string: "https://github.com/o/r/actions/runs/111/job/1"), outcome: .failed),
        PullRequestCheck(name: "unit", link: URL(string: "https://github.com/o/r/actions/runs/111/job/2"), outcome: .failed),
        PullRequestCheck(name: "lint", link: URL(string: "https://github.com/o/r/actions/runs/222"), outcome: .failed),
        PullRequestCheck(name: "CodeRabbit", link: URL(string: "https://app.coderabbit.ai/x"), outcome: .failed),
        PullRequestCheck(name: "passing", link: URL(string: "https://github.com/o/r/actions/runs/333"), outcome: .done),
      ]),
      branch: "b/x",
      logs: [testRun: log, lintRun: "lint failed: command exited 2"]
    )
    let lines = text.components(separatedBy: "\n")

    #expect(text.contains("81"))
    #expect(text.contains("https://github.com/o/r/pull/81"))
    #expect(text.contains("b/x"))
    for check in ["test", "unit", "lint", "CodeRabbit"] {
      #expect(lines.contains { $0.contains(check) && $0.contains("https://") }, "missing \(check)")
    }
    #expect(!text.contains("passing"))
    expectNoDifference(lines.filter { $0 == "line 701" || $0 == "line 1000" }, ["line 701", "line 1000"])
    #expect(!lines.contains("line 700"))
    expectNoDifference(lines.filter { $0.hasPrefix("line ") }.count, 300)
    expectNoDifference(lines.filter { $0.contains("lint failed") }.count, 1)
    expectNoDifference(lines.filter { $0.hasPrefix("## ") }.count, 2)
  }

  @Test func resolveConflictsMessageNamesTarget() {
    expectNoDifference(
      PRInstructions.resolveConflictsMessage(target: "main"),
      "Rebase your branch onto the remote branch (main) and resolve conflicts. Stage the resolved files and run `git rebase --continue`, then push --force-with-lease."
    )
  }

  @Test func fixedMessages() {
    expectNoDifference(PRInstructions.createPRMessage, "Create a PR")
    expectNoDifference(PRInstructions.commitAndPushMessage, "Commit and push all changes")
    expectNoDifference(PRInstructions.fixErrorsMessage, "Fix the failing CI actions. I've attached the failure logs.")
  }

  @Test(arguments: [
    ("b", ["b-2"], "b-3"),
    ("b", [], "b-2"),
    ("b-2", [], "b-3"),
    ("b-2", ["b-3"], "b-4"),
    ("feature/x", [], "feature/x-2"),
    ("feature-9223372036854775807", [], "feature-9223372036854775807-2"),
    ("feature-9223372036854775806", ["feature-9223372036854775807"], "feature-9223372036854775806-2"),
    ("feature-9223372036854775807", ["feature-9223372036854775807-2"], "feature-9223372036854775807-3"),
  ] as [(String, Set<String>, String)])
  func nextBranchName(branch: String, taken: Set<String>, expected: String) {
    expectNoDifference(PRInstructions.nextBranchName(after: branch, taken: taken), expected)
  }
}
