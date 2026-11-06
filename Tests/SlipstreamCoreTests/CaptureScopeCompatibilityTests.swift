import CustomDump
import Foundation
import SlipstreamCore
import Testing

struct CaptureScopeCompatibilityTests {

  @Test(arguments: ["range-git-scope", "range-git-scope-unavailable"])
  func mergedDaemonHistoryRemainsReadable(name: String) throws {
    let history = try #require(JSONSerialization.jsonObject(with: InterfaceFixtures.contents(of: "cases/\(name)/history.json")) as? [String: Any])
    let rows = try #require(history["events"] as? [[String: Any]])
    let events = try rows.map { try SlipstreamEvent.decode(JSONSerialization.data(withJSONObject: $0)) }
    for event in events {
      if case .unsupported = event.payload { Issue.record("Unsupported merged daemon event: \(event.type)") }
    }
    let scopes = events.filter { $0.type == "slipstream.capture.scope.v1" }
    expectNoDifference(scopes.first?.payload, .recordedWithoutRow)
    if name == "range-git-scope-unavailable" {
      expectNoDifference(
        scopes.first { $0.seq == Seq("5") }?.payload,
        .captureGap(CaptureGap(reason: "capture-scope-unavailable", scope: .session))
      )
    }
  }

  @Test func nonGitScopeDoesNotStopTheFeed() throws {
    let data = Data(#"{"id":"2","seq":"2","type":"slipstream.capture.scope.v1","data":{"session_id":"s","policy":"filesystem","status":"active","future":true}}"#.utf8)
    expectNoDifference(try SlipstreamEvent.decode(data).payload, .recordedWithoutRow)
  }

  @Test(arguments: [
    #"{"session_id":"s","policy":"git"}"#,
    #"{"session_id":"s","status":"active"}"#,
    #"{"policy":"git","status":"active"}"#,
    #"{"session_id":"s","policy":"filesystem","status":"unavailable"}"#,
    #"{"session_id":"s","policy":"future","status":"active"}"#,
    #"{"session_id":"s","policy":"git","status":"future"}"#,
  ])
  func malformedScopeIsRejected(payload: String) {
    let data = Data("{\"id\":\"2\",\"seq\":\"2\",\"type\":\"slipstream.capture.scope.v1\",\"data\":\(payload)}".utf8)
    #expect(throws: EventDecodingError(seq: "2", type: "slipstream.capture.scope.v1")) {
      try SlipstreamEvent.decode(data)
    }
  }

  @Test(arguments: [
    ["store-directory", ".git", "symlinks", "git-ignored", "git-ignored"],
    ["store-directory", ".git", "symlinks", "git-ignored", "ignore-rules"],
  ])
  func invalidExclusionListsRemainRejected(exclusions: [String]) throws {
    var page = try #require(JSONSerialization.jsonObject(with: InterfaceFixtures.expected("range-git-scope")) as? [String: Any])
    var inventory = try #require(page["inventory"] as? [String: Any])
    inventory["policy_exclusions"] = exclusions
    page["inventory"] = inventory
    let data = try JSONSerialization.data(withJSONObject: page)
    #expect(throws: InterfaceDecodingError.self) { try InterfaceComparison.decode(data) }
  }
}
