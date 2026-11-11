import Foundation

/// The text the PR bar hands to the agent: the instruction files, the fixed chat messages, and the
/// next-branch-name rule.
public enum PRInstructions {
  public enum Upstream: Equatable, Sendable {
    case none
    case inSync(String)
    case unpushed(Int)
  }

  public static let createPRMessage = "Create a PR"
  public static let commitAndPushMessage = "Commit and push all changes"
  public static let fixErrorsMessage = "Fix the failing CI actions. I've attached the failure logs."

  private static let logTailLines = 300

  public static func createPR(uncommitted: Int, branch: String, target: String, upstream: Upstream) -> String {
    let upstreamLine =
      switch upstream {
      case .none: "There is no upstream branch yet."
      case .inSync(let name): "The upstream branch is \(name)."
      case .unpushed(let count): "There are \(count) unpushed commits."
      }
    return """
      The user likes the current state of the code.

      There are \(uncommitted) uncommitted changes.
      The current branch is \(branch).
      The target branch is origin/\(target).

      \(upstreamLine)
      The user requested a PR.

      Follow these steps to create a PR:

      - If you have any skills related to creating PRs, invoke them now. Instructions there should take precedence over these instructions.
      - Run `git diff` to review uncommitted changes
      - Commit them. Follow any instructions the user gave you about writing commit messages.
      - Push to origin.
      - Run `git diff origin/\(target)...HEAD` to review the PR diff
      - Use `gh pr create --base \(target)` to create a PR onto the target branch. Keep the title under 80 characters. Keep the description under five sentences, unless the user instructed you otherwise. Describe not just changes made in this session but ALL changes in the workspace diff.

      If any of these steps fail, ask the user for help.
      """
  }

  /// `logs` holds, per Actions run behind a failed check, either its failed-step log or the failed
  /// command and its output.
  public static func fixErrors(pullRequest: GitHubPullRequest, branch: String, logs: [ActionsRun: String]) -> String {
    let failed = pullRequest.statusCheckRollup.filter { $0.outcome == .failed }
    let checkLines = failed.map { check in
      check.link.map { "- \(check.name): \($0.absoluteString)" } ?? "- \(check.name)"
    }
    var sections = [
      (["Pull request #\(pullRequest.number): \(pullRequest.url.absoluteString)", "Branch: \(branch)", "", "Failed checks:"] + checkLines)
        .joined(separator: "\n")
    ]
    var seen: Set<ActionsRun> = []
    for run in failed.compactMap({ $0.link.flatMap(ActionsRun.init(link:)) }) where seen.insert(run).inserted {
      guard let log = logs[run] else { continue }
      sections.append("## \(run.repository) run \(run.id)\n\(tail(log))")
    }
    return sections.joined(separator: "\n\n")
  }

  public static func resolveConflictsMessage(target: String) -> String {
    "Rebase your branch onto the remote branch (\(target)) and resolve conflicts. Stage the resolved files and run `git rebase --continue`, then push --force-with-lease."
  }

  /// Increments an existing `-N` suffix, otherwise appends `-2`; skips names in `taken`.
  public static func nextBranchName(after branch: String, taken: Set<String>) -> String {
    var base = branch
    var number = 2
    if let match = branch.wholeMatch(of: /(.+)-(\d+)/), let existing = Int(match.2) {
      base = String(match.1)
      number = existing + 1
    }
    while taken.contains("\(base)-\(number)") { number += 1 }
    return "\(base)-\(number)"
  }

  private static func tail(_ log: String) -> String {
    var lines = log.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last == "" { lines.removeLast() }
    return lines.suffix(logTailLines).joined(separator: "\n")
  }
}
