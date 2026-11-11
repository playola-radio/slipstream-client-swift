import CustomDump
import Foundation
import SlipstreamCore
import Testing

private func decodeCheck(_ json: String) throws -> PullRequestCheck {
  try JSONDecoder().decode(PullRequestCheck.self, from: Data(json.utf8))
}

struct PullRequestsTests {
  @Test func decodesPullRequestList() throws {
    let url = try #require(Bundle.module.url(forResource: "gh-pr-list", withExtension: "json", subdirectory: "Fixtures"))
    let list = try JSONDecoder().decode([GitHubPullRequest].self, from: Data(contentsOf: url))
    let pullRequest = try #require(list.first)

    expectNoDifference(list.count, 1)
    expectNoDifference(pullRequest.number, 80)
    expectNoDifference(pullRequest.state, .merged)
    expectNoDifference(pullRequest.headRefOid, "007da331c3b6f973700e4a35cb7eeb131dd20620")
    expectNoDifference(pullRequest.reviewDecision, "CHANGES_REQUESTED")
    expectNoDifference(pullRequest.statusCheckRollup.map(\.outcome), [.done, .done, .done, .running])
    expectNoDifference(
      pullRequest.statusCheckRollup.last,
      PullRequestCheck(name: "ci/legacy", link: URL(string: "https://ci.example.com/builds/80"), outcome: .running)
    )
  }

  @Test(arguments: [
    (#"{"__typename":"CheckRun","name":"c","status":"COMPLETED","conclusion":"FAILURE"}"#, PullRequestCheck.Outcome.failed),
    (#"{"__typename":"CheckRun","name":"c","status":"COMPLETED","conclusion":"TIMED_OUT"}"#, .failed),
    (#"{"__typename":"CheckRun","name":"c","status":"COMPLETED","conclusion":"ACTION_REQUIRED"}"#, .failed),
    (#"{"__typename":"CheckRun","name":"c","status":"COMPLETED","conclusion":"STARTUP_FAILURE"}"#, .failed),
    (#"{"__typename":"StatusContext","context":"c","state":"FAILURE"}"#, .failed),
    (#"{"__typename":"StatusContext","context":"c","state":"ERROR"}"#, .failed),
    (#"{"__typename":"CheckRun","name":"c","status":"IN_PROGRESS","conclusion":""}"#, .running),
    (#"{"__typename":"StatusContext","context":"c","state":"EXPECTED"}"#, .running),
    (#"{"__typename":"CheckRun","name":"c","status":"COMPLETED","conclusion":null}"#, .done),
    (#"{"__typename":"CheckRun","name":"c","status":"COMPLETED","conclusion":"CANCELLED"}"#, .done),
    (#"{"__typename":"StatusContext","context":"c","state":"SUCCESS"}"#, .done),
    (#"{"__typename":"Mystery","name":"c"}"#, .done),
  ])
  func classifiesCheck(json: String, expected: PullRequestCheck.Outcome) throws {
    expectNoDifference(try decodeCheck(json).outcome, expected)
  }

  @Test func unknownCheckKindIsNamedByItsNameOrFallback() throws {
    expectNoDifference(try decodeCheck(#"{"__typename":"Mystery","name":"odd"}"#).name, "odd")
    expectNoDifference(try decodeCheck(#"{"__typename":"Mystery"}"#).name, "Unknown check")
  }

  @Test(arguments: [
    ("https://github.com/playola-radio/slipstream-client-swift/actions/runs/43083706363/job/130742532911",
     ActionsRun(repository: "playola-radio/slipstream-client-swift", id: "43083706363")),
    ("https://github.com/playola-radio/slipstream-client-swift/actions/runs/43083706363",
     ActionsRun(repository: "playola-radio/slipstream-client-swift", id: "43083706363")),
    ("https://app.coderabbit.ai/change-stack/playola-radio/slipstream-client-swift/pull/80", nil),
  ] as [(String, ActionsRun?)])
  func parsesActionsRun(link: String, expected: ActionsRun?) throws {
    expectNoDifference(ActionsRun(link: try #require(URL(string: link))), expected)
  }

  @Test func decodesRepository() throws {
    let json = #"{"defaultBranchRef":{"name":"develop"},"isFork":false,"viewerDefaultMergeMethod":"MERGE"}"#
    expectNoDifference(
      try JSONDecoder().decode(GitHubRepository.self, from: Data(json.utf8)),
      GitHubRepository(isFork: false, defaultBranch: "develop", mergeMethod: "MERGE")
    )
  }
}
