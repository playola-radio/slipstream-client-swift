import CustomDump
import Foundation
import SlipstreamCore
import Testing
@testable import SlipstreamViewer

struct CaptureStatusTests {
  static let checkedAt = Date(timeIntervalSince1970: 1_792_341_727)
  static let utc = TimeZone(identifier: "UTC")!

  static func status(
    _ state: CaptureState, reason: String? = nil, retryAtMs: Int64? = nil, binding: CaptureBinding? = nil
  ) -> CaptureStatus {
    CaptureStatus(
      availability: .available(checkedAt: checkedAt),
      capture: CaptureSummary(
        sessionID: "s", root: "/work/nairobi", state: state, reason: reason, retryAtMs: retryAtMs, binding: binding)
    )
  }

  static let linked = CaptureBinding(generation: "7", state: .connected)

  @Test(arguments: [
    (CaptureState.recording, nil, "Recording"),
    (.baselining, nil, "Preparing — not recording yet"),
    (.queued, nil, "Queued — not recording yet"),
    (.stopped, "detached", "Stopped — capture detached"),
    (.stopped, "archived", "Stopped — workspace archived"),
    (.stopped, "maintenance", "Stopped — maintenance in progress"),
    (.stopped, "root-missing", "Stopped — workspace folder missing or replaced"),
    (.stopped, "watcher-failed", "Stopped — file watcher failed"),
    (.stopped, nil, "Stopped"),
    (.stopped, "disk-quota", "Stopped — unrecognised reason “disk-quota”"),
    (.notRecording, "capture-limit-reached", "Not recording — waiting for a free capture slot"),
    (.notRecording, "daemon-unavailable", "Not recording — Slipstream stopped reporting on this capture"),
    (.notRecording, "root-overlap", "Not recording — folder overlaps another capture"),
    (.notRecording, "root-missing", "Not recording — workspace folder missing or replaced"),
    (.notRecording, "baseline-failed", "Not recording — first snapshot failed"),
    (.notRecording, "storage-unavailable", "Not recording — storage unavailable"),
    (.notRecording, "watcher-failed", "Not recording — file watcher failed"),
    (.notRecording, "resume-failed", "Not recording — capture couldn't resume"),
    (.notRecording, "resource-limit", "Not recording — system resource limit reached"),
    (.notRecording, "stop-unconfirmed", "Not recording — stop couldn't be confirmed"),
    (.notRecording, "disk-quota", "Not recording — unrecognised reason “disk-quota”"),
    (.notRecording, nil, "Not recording"),
    (.unknown("hibernating"), nil, "Capture state unknown — unrecognised state “hibernating”"),
  ] as [(CaptureState, String?, String)])
  func captureTextNamesTheStateAndReason(state: CaptureState, reason: String?, text: String) {
    expectNoDifference(Self.status(state, reason: reason).captureText, text)
  }

  @Test func captureTextWithoutASnapshotSaysWhy() {
    expectNoDifference(CaptureStatus(availability: .loading, capture: nil).captureText, "Checking capture state…")
    expectNoDifference(
      CaptureStatus(availability: .unavailableFromReader, capture: nil).captureText,
      "Capture state unavailable from this reader")
    expectNoDifference(
      CaptureStatus(availability: .failed, capture: nil).captureText,
      "Capture state unknown — couldn't reach Slipstream")
    expectNoDifference(
      CaptureStatus(availability: .available(checkedAt: Self.checkedAt), capture: nil).captureText,
      "Not captured — Slipstream has no capture for this workspace")
  }

  @Test func onlyARecordingSnapshotReadsRecording() {
    let readings: [CaptureStatus] = [
      Self.status(.baselining), Self.status(.queued), Self.status(.stopped, reason: "maintenance"),
      Self.status(.notRecording, reason: "capture-limit-reached"), Self.status(.unknown("recording-ish")),
      CaptureStatus(availability: .loading, capture: nil),
      CaptureStatus(availability: .failed, capture: nil),
      CaptureStatus(availability: .unavailableFromReader, capture: nil),
      CaptureStatus(availability: .available(checkedAt: Self.checkedAt), capture: nil),
    ]
    for status in readings {
      #expect(status.captureText != "Recording")
      #expect(status.pickerSuffix != "Recording")
      #expect(status.captureDot != .recording)
    }
  }

  @Test func detailExplainsWaitingStatesAndRetries() {
    expectNoDifference(
      Self.status(.baselining).detailText(timeZone: Self.utc),
      "Taking the first snapshot of this workspace. Changes aren't covered until it finishes.")
    expectNoDifference(
      Self.status(.queued).detailText(timeZone: Self.utc),
      "Slipstream has accepted this workspace and will start it shortly. Refresh to check again.")
    expectNoDifference(
      Self.status(.notRecording, reason: "capture-limit-reached").detailText(timeZone: Self.utc),
      "Every capture slot is in use. This workspace starts on its own, oldest first, when one frees up. Refresh to check again.")
    expectNoDifference(
      Self.status(.stopped, reason: "maintenance").detailText(timeZone: Self.utc),
      "Slipstream is cleaning up its storage. Capture resumes on its own afterwards. Refresh to check again.")
    expectNoDifference(
      Self.status(.unknown("hibernating")).detailText(timeZone: Self.utc),
      "Update Slipstream Viewer to read this state.")
    #expect(Self.status(.recording).detailText(timeZone: Self.utc) == nil)
    #expect(Self.status(.stopped, reason: "archived").detailText(timeZone: Self.utc) == nil)
  }

  @Test func retryTimeIsShownInTheInjectedTimeZone() {
    let status = Self.status(.notRecording, reason: "baseline-failed", retryAtMs: 1_792_341_900_000)
    expectNoDifference(status.detailText(timeZone: Self.utc), "Retry scheduled Oct 18 16:45:00")
    expectNoDifference(
      status.detailText(timeZone: TimeZone(identifier: "America/Chicago")!), "Retry scheduled Oct 18 11:45:00")
  }

  @Test func checkedTimeShowsOnlyForALoadedSnapshot() {
    expectNoDifference(Self.status(.recording).checkedText(timeZone: Self.utc), "Checked 16:42:07")
    #expect(CaptureStatus(availability: .loading, capture: nil).checkedText(timeZone: Self.utc) == nil)
    #expect(CaptureStatus(availability: .failed, capture: nil).checkedText(timeZone: Self.utc) == nil)
    #expect(CaptureStatus(availability: .unavailableFromReader, capture: nil).checkedText(timeZone: Self.utc) == nil)
  }

  @Test(arguments: [
    (CaptureState.recording, nil, "Recording"),
    (.notRecording, "capture-limit-reached", "Waiting for a free slot"),
    (.notRecording, "root-overlap", "Not recording"),
    (.queued, nil, "Queued"),
    (.baselining, nil, "Preparing"),
    (.stopped, "archived", "Stopped"),
    (.unknown("hibernating"), nil, "State unknown"),
  ] as [(CaptureState, String?, String)])
  func pickerSuffixIsShort(state: CaptureState, reason: String?, suffix: String) {
    expectNoDifference(Self.status(state, reason: reason).pickerSuffix, suffix)
  }

  @Test func pickerSuffixWithoutACapture() {
    #expect(CaptureStatus(availability: .loading, capture: nil).pickerSuffix == nil)
    expectNoDifference(CaptureStatus(availability: .failed, capture: nil).pickerSuffix, "State unknown")
    expectNoDifference(CaptureStatus(availability: .unavailableFromReader, capture: nil).pickerSuffix, "State unknown")
    expectNoDifference(
      CaptureStatus(availability: .available(checkedAt: Self.checkedAt), capture: nil).pickerSuffix, "Not captured")
  }

  @Test func captureDots() {
    expectNoDifference(Self.status(.recording).captureDot, .recording)
    for status in [
      Self.status(.queued), Self.status(.baselining), Self.status(.stopped, reason: "detached"),
      Self.status(.notRecording, reason: "disk-quota"),
    ] {
      expectNoDifference(status.captureDot, .attention)
    }
    for status in [
      Self.status(.unknown("hibernating")), CaptureStatus(availability: .loading, capture: nil),
      CaptureStatus(availability: .failed, capture: nil),
      CaptureStatus(availability: .unavailableFromReader, capture: nil),
      CaptureStatus(availability: .available(checkedAt: Self.checkedAt), capture: nil),
    ] {
      expectNoDifference(status.captureDot, .unknown)
    }
  }

  @Test(arguments: [
    (CaptureBinding?.none, "No chat linked", CaptureDot.noChat),
    (CaptureBinding(generation: "1", state: .unlinked), "No chat linked", .noChat),
    (CaptureBinding(generation: "1", state: .connected), "Linked — changes are possibly the agent's", .linked),
    (CaptureBinding(generation: "1", state: .setupPending),
     "Waiting for setup — the chat hasn't confirmed it can answer yet", .attention),
    (CaptureBinding(generation: "1", state: .setupPending, reason: "config-missing"),
     "Waiting for setup — setup configuration missing", .attention),
    (CaptureBinding(generation: "1", state: .unavailable, reason: "transcript-missing"),
     "Unavailable — chat transcript missing", .attention),
    (CaptureBinding(generation: "1", state: .unavailable, reason: "transcript-unreadable"),
     "Unavailable — chat transcript unreadable", .attention),
    (CaptureBinding(generation: "1", state: .unavailable, reason: "identity-changed"),
     "Unavailable — chat identity changed", .attention),
    (CaptureBinding(generation: "1", state: .unavailable, reason: "runtime-unsupported"),
     "Unavailable — agent runtime unsupported", .attention),
    (CaptureBinding(generation: "1", state: .unavailable, reason: "lost"),
     "Unavailable — unrecognised reason “lost”", .attention),
    (CaptureBinding(generation: "1", state: .unknown("paused")),
     "Chat-link state unknown — unrecognised state “paused”", .unknown),
  ] as [(CaptureBinding?, String, CaptureDot)])
  func chatTextFollowsTheBinding(binding: CaptureBinding?, text: String, dot: CaptureDot) {
    let status = Self.status(.recording, binding: binding)
    expectNoDifference(status.chatText, text)
    expectNoDifference(status.chatDot, dot)
  }

  @Test func chatTextWithoutASnapshot() {
    let loading = CaptureStatus(availability: .loading, capture: nil)
    expectNoDifference(loading.chatText, "Checking chat link…")
    expectNoDifference(loading.chatDot, .unknown)
    for status in [
      CaptureStatus(availability: .failed, capture: nil),
      CaptureStatus(availability: .unavailableFromReader, capture: nil),
    ] {
      expectNoDifference(status.chatText, "Chat-link state unknown")
      expectNoDifference(status.chatDot, .unknown)
    }
    let notCaptured = CaptureStatus(availability: .available(checkedAt: Self.checkedAt), capture: nil)
    expectNoDifference(notCaptured.chatText, "No chat linked")
    expectNoDifference(notCaptured.chatDot, .noChat)
  }

  @Test func chatTextIsUnknownWhenSlipstreamStoppedReporting() {
    let status = Self.status(.notRecording, reason: "daemon-unavailable", binding: Self.linked)
    expectNoDifference(status.chatText, "Chat-link state unknown")
    expectNoDifference(status.chatDot, .unknown)
  }

  @Test(arguments: [linked, nil] as [CaptureBinding?])
  func chatTextIsUnknownWhenTheCaptureStateIsUnknown(binding: CaptureBinding?) {
    let status = Self.status(.unknown("hibernating"), binding: binding)
    expectNoDifference(status.chatText, "Chat-link state unknown")
    expectNoDifference(status.chatDot, .unknown)
  }

  @Test func askIsAllowedOnlyWhenRecordingLinkedAndReady() {
    #expect(Self.status(.recording, binding: Self.linked).askNotice(agentConnection: .connected) == nil)
  }

  @Test func askNoticeFollowsThePrecedence() {
    let unknown = "Capture state is unknown, so questions are disabled. Refresh to check again."
    let notRecording = "This workspace isn't recording, so its chat can't receive questions."
    let noChat = "No agent chat is linked to this workspace. Run `slipstream attach` inside the agent chat to link one."
    let waiting = "The agent chat hasn't confirmed it can answer yet. It confirms on its next tool call after `slipstream attach`."

    expectNoDifference(
      CaptureStatus(availability: .failed, capture: nil).askNotice(agentConnection: .connected), unknown)
    expectNoDifference(
      CaptureStatus(availability: .unavailableFromReader, capture: nil).askNotice(agentConnection: .connected), unknown)
    expectNoDifference(
      CaptureStatus(availability: .loading, capture: nil).askNotice(agentConnection: .connected), unknown)
    expectNoDifference(Self.status(.unknown("hibernating")).askNotice(agentConnection: .connected), unknown)
    expectNoDifference(
      Self.status(.stopped, reason: "archived", binding: CaptureBinding(generation: "1", state: .unknown("paused")))
        .askNotice(agentConnection: .connected),
      unknown)
    expectNoDifference(
      CaptureStatus(availability: .available(checkedAt: Self.checkedAt), capture: nil)
        .askNotice(agentConnection: .connected),
      notRecording)
    expectNoDifference(
      Self.status(.stopped, reason: "archived", binding: Self.linked).askNotice(agentConnection: .connected),
      notRecording)
    expectNoDifference(Self.status(.recording).askNotice(agentConnection: .connected), noChat)
    expectNoDifference(
      Self.status(.recording, binding: CaptureBinding(generation: "1", state: .unlinked))
        .askNotice(agentConnection: .connected),
      noChat)
    expectNoDifference(
      Self.status(.recording, binding: CaptureBinding(generation: "1", state: .unavailable, reason: "transcript-missing"))
        .askNotice(agentConnection: .connected),
      "The linked chat is unavailable (chat transcript missing), so questions are disabled.")
    expectNoDifference(
      Self.status(.recording, binding: CaptureBinding(generation: "1", state: .setupPending))
        .askNotice(agentConnection: .connected),
      waiting)
    expectNoDifference(Self.status(.recording, binding: Self.linked).askNotice(agentConnection: .setupPending), waiting)
    expectNoDifference(Self.status(.recording, binding: Self.linked).askNotice(agentConnection: .unreported), waiting)
  }
}
