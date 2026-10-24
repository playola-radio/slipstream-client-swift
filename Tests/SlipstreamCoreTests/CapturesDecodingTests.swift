import CustomDump
import Foundation
import Testing

@testable import SlipstreamCore

struct CapturesDecodingTests {
  private static let session = "0f8c2a4e-5b1d-4c3e-9a7f-2d6b8e1c4a90"

  private static func row(
    state: String = "\"recording\"", reason: String = "null", retry: String = "null",
    binding: String = "null"
  ) -> String {
    """
    {"session_id":"\(session)","root":"/w/nairobi","state":\(state),"reason":\(reason),"retry":\(retry),\
    "capture_mode":"watch-only","heartbeat_ms":1792252566120,"binding":\(binding),"message":"ignored"}
    """
  }

  private static func list(_ rows: String...) -> Data {
    Data(#"{"as_of_ms":1792252567000,"binding_slots":{"used":1,"limit":10},"captures":[\#(rows.joined(separator: ","))]}"#.utf8)
  }

  private static func decode(_ data: Data) throws -> CaptureList {
    try JSONDecoder().decode(CaptureList.self, from: data)
  }

  private static func ok(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "http://127.0.0.1:4100/v1/captures")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
  }

  @Test func decodesTheDocumentedExample() throws {
    let binding = #"{"harness":"claude-code","harness_session_id":"5c1e","binding_generation":"3","state":"connected","reason":null}"#
    expectNoDifference(
      try Self.decode(Self.list(Self.row(binding: binding))),
      CaptureList(captures: [
        CaptureSummary(
          sessionID: Self.session, root: "/w/nairobi", state: .recording,
          binding: CaptureBinding(generation: "3", state: .connected, harnessSessionID: "5c1e"))
      ])
    )
  }

  @Test(arguments: [
    ("queued", CaptureState.queued),
    ("baselining", .baselining),
    ("recording", .recording),
    ("stopped", .stopped),
    ("not_recording", .notRecording),
    ("hibernating", .unknown("hibernating")),
  ])
  func decodesEveryCaptureState(raw: String, expected: CaptureState) throws {
    let capture = try #require(try Self.decode(Self.list(Self.row(state: "\"\(raw)\""))).captures.first)
    expectNoDifference(capture.state, expected)
  }

  @Test(arguments: [
    "detached", "archived", "maintenance", "root-missing", "watcher-failed",
    "daemon-unavailable", "root-overlap", "baseline-failed", "storage-unavailable", "resume-failed",
    "resource-limit", "stop-unconfirmed", "capture-limit-reached", "disk-quota",
  ])
  func keepsEveryReasonRaw(reason: String) throws {
    let capture = try #require(
      try Self.decode(Self.list(Self.row(state: "\"not_recording\"", reason: "\"\(reason)\""))).captures.first)
    expectNoDifference(capture.reason, reason)
  }

  @Test func readsTheRetryTime() throws {
    let capture = try #require(
      try Self.decode(Self.list(Self.row(state: "\"not_recording\"", reason: "\"baseline-failed\"", retry: #"{"next_attempt_at_ms":1792255500000}"#))).captures.first)
    expectNoDifference(capture.retryAtMs, 1_792_255_500_000)
  }

  @Test(arguments: [
    ("setup_pending", BindingState.setupPending, "\"config-missing\"", Optional("config-missing")),
    ("setup_pending", .setupPending, "null", nil),
    ("connected", .connected, "null", nil),
    ("unavailable", .unavailable, "\"transcript-missing\"", "transcript-missing"),
    ("unavailable", .unavailable, "\"transcript-unreadable\"", "transcript-unreadable"),
    ("unavailable", .unavailable, "\"identity-changed\"", "identity-changed"),
    ("unavailable", .unavailable, "\"runtime-unsupported\"", "runtime-unsupported"),
    ("unlinked", .unlinked, "null", nil),
    ("paused", .unknown("paused"), "null", nil),
  ])
  func decodesEveryBindingState(raw: String, expected: BindingState, wireReason: String, reason: String?) throws {
    let binding = #"{"harness":"codex","harness_session_id":"x","binding_generation":"9007199254740993","state":"\#(raw)","reason":\#(wireReason)}"#
    let capture = try #require(try Self.decode(Self.list(Self.row(binding: binding))).captures.first)
    expectNoDifference(
      capture.binding,
      CaptureBinding(generation: "9007199254740993", state: expected, reason: reason, harnessSessionID: "x"))
  }

  @Test func bindingDecodesChatID() throws {
    let binding = #"{"harness":"claude-code","harness_session_id":"0B8E6C52-1F3A-4D2B-9C1E-7A5F3E2D1C0B","binding_generation":"3","state":"connected","reason":null}"#
    let capture = try #require(try Self.decode(Self.list(Self.row(binding: binding))).captures.first)
    expectNoDifference(capture.binding?.harnessSessionID, "0B8E6C52-1F3A-4D2B-9C1E-7A5F3E2D1C0B")
  }

  @Test func bindingWithoutChatIDStillDecodes() throws {
    let binding = #"{"harness":"claude-code","binding_generation":"3","state":"connected","reason":null}"#
    let capture = try #require(try Self.decode(Self.list(Self.row(binding: binding))).captures.first)
    expectNoDifference(capture.binding, CaptureBinding(generation: "3", state: .connected))
  }

  private static let chat = UUID(uuidString: "0B8E6C52-1F3A-4D2B-9C1E-7A5F3E2D1C0B")!

  @Test func isLinkedMatchesUUIDCaseInsensitively() {
    let binding = CaptureBinding(
      generation: "3", state: .connected, harnessSessionID: "0b8e6c52-1f3a-4d2b-9c1e-7a5f3e2d1c0b")
    #expect(binding.isLinked(toChat: Self.chat))
  }

  @Test func isLinkedFalseWhenUnlinkedWithOldID() {
    let binding = CaptureBinding(generation: "3", state: .unlinked, harnessSessionID: Self.chat.uuidString)
    #expect(!binding.isLinked(toChat: Self.chat))
  }

  @Test func isLinkedTrueWhenSetupPending() {
    let binding = CaptureBinding(generation: "3", state: .setupPending, harnessSessionID: Self.chat.uuidString)
    #expect(binding.isLinked(toChat: Self.chat))
  }

  @Test func isLinkedFalseForAnotherChat() {
    let binding = CaptureBinding(generation: "3", state: .connected, harnessSessionID: "5c1e7a2b-0000-4000-8000-000000000001")
    #expect(!binding.isLinked(toChat: Self.chat))
  }

  @Test func decodesAnEmptyList() throws {
    expectNoDifference(try Self.decode(Self.list()), CaptureList(captures: []))
  }

  @Test(arguments: [
    #"{"session_id":"s","root":"/w","state":"recording","retry":null,"binding":null}"#,
    #"{"session_id":"s","root":"/w","state":"recording","reason":null,"binding":null}"#,
    #"{"session_id":"s","root":"/w","state":"recording","reason":null,"retry":null}"#,
    #"{"root":"/w","state":"recording","reason":null,"retry":null,"binding":null}"#,
    #"{"session_id":"s","root":"/w","state":7,"reason":null,"retry":null,"binding":null}"#,
    #"{"session_id":"s","root":"/w","state":"recording","reason":null,"retry":{},"binding":null}"#,
    #"{"session_id":"s","root":"/w","state":"recording","reason":null,"retry":null,"binding":{"binding_generation":3,"state":"connected","reason":null}}"#,
    #"{"session_id":"s","root":"/w","state":"recording","reason":null,"retry":null,"binding":{"binding_generation":"3","state":null,"reason":null}}"#,
  ])
  func aMissingKeyOrWrongTypeFailsTheWholeList(row: String) {
    #expect(throws: (any Error).self) { try Self.decode(Self.list(Self.row(), row)) }
  }

  @Test func aListWithoutCapturesFails() {
    #expect(throws: (any Error).self) { try Self.decode(Data(#"{"as_of_ms":1}"#.utf8)) }
  }

  @Test func notFoundMeansTheReaderHasNoCaptureTable() throws {
    #expect(try DaemonTransport.captureList(Data("Not Found".utf8), response: Self.ok(404)) == nil)
  }

  @Test func otherStatusesThrow() {
    for status in [401, 403, 500] {
      #expect(throws: DaemonHTTPError.status(status, durableSeq: nil)) {
        try DaemonTransport.captureList(Data(), response: Self.ok(status))
      }
    }
  }

  @Test func anOKResponseDecodes() throws {
    expectNoDifference(
      try DaemonTransport.captureList(Self.list(), response: Self.ok(200)),
      CaptureList(captures: []))
  }
}
