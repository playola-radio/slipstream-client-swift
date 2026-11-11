import Foundation

/// One pull request from `gh pr list --json`. `mergeable`, `mergeStateStatus` and `reviewDecision`
/// stay raw so values GitHub adds later fall through to a generic waiting state.
public struct GitHubPullRequest: Decodable, Equatable, Sendable {
  public enum State: String, Decodable, Equatable, Sendable {
    case open = "OPEN"
    case merged = "MERGED"
    case closed = "CLOSED"
  }

  public var number: Int
  public var url: URL
  public var state: State
  public var isDraft: Bool
  public var headRefOid: String
  public var isCrossRepository: Bool
  public var baseRefName: String
  public var mergeable: String
  public var mergeStateStatus: String
  public var reviewDecision: String?
  public var statusCheckRollup: [PullRequestCheck]

  public init(
    number: Int,
    url: URL,
    state: State,
    isDraft: Bool,
    headRefOid: String,
    isCrossRepository: Bool,
    baseRefName: String,
    mergeable: String,
    mergeStateStatus: String,
    reviewDecision: String?,
    statusCheckRollup: [PullRequestCheck]
  ) {
    self.number = number
    self.url = url
    self.state = state
    self.isDraft = isDraft
    self.headRefOid = headRefOid
    self.isCrossRepository = isCrossRepository
    self.baseRefName = baseRefName
    self.mergeable = mergeable
    self.mergeStateStatus = mergeStateStatus
    self.reviewDecision = reviewDecision
    self.statusCheckRollup = statusCheckRollup
  }
}

/// One `statusCheckRollup` entry, normalized from a `CheckRun` or a `StatusContext`.
public struct PullRequestCheck: Decodable, Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case failed
    case running
    case done
  }

  public var name: String
  public var link: URL?
  public var outcome: Outcome

  public init(name: String, link: URL?, outcome: Outcome) {
    self.name = name
    self.link = link
    self.outcome = outcome
  }

  private enum CodingKeys: String, CodingKey {
    case typename = "__typename"
    case name, detailsUrl, status, conclusion
    case context, targetUrl, state
  }

  private static let failedConclusions: Set<String> = ["FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]
  private static let failedStates: Set<String> = ["FAILURE", "ERROR"]
  private static let runningStates: Set<String> = ["PENDING", "EXPECTED"]

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .typename) {
    case "CheckRun":
      name = try container.decode(String.self, forKey: .name)
      link = try container.decodeIfPresent(URL.self, forKey: .detailsUrl)
      let status = try container.decodeIfPresent(String.self, forKey: .status)
      let conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)
      if let conclusion, Self.failedConclusions.contains(conclusion) {
        outcome = .failed
      } else if let status, status != "COMPLETED" {
        outcome = .running
      } else {
        outcome = .done
      }
    case "StatusContext":
      name = try container.decode(String.self, forKey: .context)
      link = try container.decodeIfPresent(URL.self, forKey: .targetUrl)
      let state = try container.decodeIfPresent(String.self, forKey: .state)
      if let state, Self.failedStates.contains(state) {
        outcome = .failed
      } else if let state, Self.runningStates.contains(state) {
        outcome = .running
      } else {
        outcome = .done
      }
    default:
      name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown check"
      link = nil
      outcome = .done
    }
  }
}

/// `gh repo view --json isFork,defaultBranchRef,viewerDefaultMergeMethod`.
public struct GitHubRepository: Decodable, Equatable, Sendable {
  public var isFork: Bool
  public var defaultBranch: String
  public var mergeMethod: String
  public var nameWithOwner: String

  public init(isFork: Bool, defaultBranch: String, mergeMethod: String, nameWithOwner: String) {
    self.isFork = isFork
    self.defaultBranch = defaultBranch
    self.mergeMethod = mergeMethod
    self.nameWithOwner = nameWithOwner
  }

  private enum CodingKeys: String, CodingKey {
    case isFork, defaultBranchRef, viewerDefaultMergeMethod, nameWithOwner
  }

  private struct BranchRef: Decodable {
    var name: String
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isFork = try container.decode(Bool.self, forKey: .isFork)
    defaultBranch = try container.decode(BranchRef.self, forKey: .defaultBranchRef).name
    mergeMethod = try container.decode(String.self, forKey: .viewerDefaultMergeMethod)
    nameWithOwner = try container.decode(String.self, forKey: .nameWithOwner)
  }
}

/// A GitHub Actions run, identified by `<owner>/<repo>` and run id, parsed from a check link of the form
/// `https://github.com/<owner>/<repo>/actions/runs/<run-id>[/job/<job-id>]`.
public struct ActionsRun: Hashable, Sendable {
  public var repository: String
  public var id: String

  public init(repository: String, id: String) {
    self.repository = repository
    self.id = id
  }

  public init?(link: URL) {
    let parts = link.pathComponents
    guard link.host == "github.com",
      parts.count >= 6, parts[1...2].allSatisfy({ !$0.isEmpty }),
      parts[3] == "actions", parts[4] == "runs",
      !parts[5].isEmpty, parts[5].allSatisfy(\.isASCII), parts[5].allSatisfy(\.isNumber)
    else { return nil }
    self.init(repository: "\(parts[1])/\(parts[2])", id: parts[5])
  }
}
