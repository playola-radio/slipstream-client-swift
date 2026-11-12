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
  static let tab = UUID(uuidString: "5896F28C-F4A9-46C2-B481-7CA57E8714A8")!

  @Test(arguments: [
    (CaptureState.recording, nil, "Recording"),
    (.baselining, nil, "Preparing — not recording yet"),
    (.queued, nil, "Queued — not recording yet"),
    (.stopped, "detached", "Paused"),
    (.stopped, "archived", "Stopped — workspace archived"),
    (.stopped, "maintenance", "Stopped — maintenance in progress"),
    (.stopped, "root-missing", "Stopped — workspace folder missing or replaced"),
    (.stopped, "watcher-failed", "Stopped — file watcher failed"),
    (.stopped, nil, "Stopped"),
    (.stopped, "disk-quota", "Stopped — unrecognised reason “disk-quota”"),
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
      "Capture state unknown — the capture list didn't load")
    expectNoDifference(
      CaptureStatus(availability: .available(checkedAt: Self.checkedAt), capture: nil).captureText,
      "Not captured — Slipstream has no capture for this workspace")
  }

  @Test func onlyARecordingSnapshotReadsRecording() {
    let readings: [CaptureStatus] = [
      Self.status(.baselining), Self.status(.queued), Self.status(.stopped, reason: "maintenance"),
      Self.status(.notRecording, reason: "root-overlap"), Self.status(.unknown("recording-ish")),
      CaptureStatus(availability: .loading, capture: nil),
      CaptureStatus(availability: .failed, capture: nil),
      CaptureStatus(availability: .unavailableFromReader, capture: nil),
      CaptureStatus(availability: .available(checkedAt: Self.checkedAt), capture: nil),
    ]
    for status in readings {
      #expect(status.captureText != "Recording")
      #expect(status.captureDot != .recording)
    }
  }

  @Test func detailExplainsWaitingStatesAndRetries() {
    expectNoDifference(
      Self.status(.baselining).detailText(timeZone: Self.utc),
      "Taking the first snapshot of this workspace. Changes aren't covered until it finishes.")
    expectNoDifference(
      Self.status(.queued).detailText(timeZone: Self.utc),
      "Slipstream has accepted this workspace and will start it shortly. Press ⌘R to check again.")
    expectNoDifference(
      Self.status(.stopped, reason: "maintenance").detailText(timeZone: Self.utc),
      "Slipstream is cleaning up its storage. Capture resumes on its own afterwards. Press ⌘R to check again.")
    expectNoDifference(
      Self.status(.unknown("hibernating")).detailText(timeZone: Self.utc),
      "Update Slipstream to read this state.")
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
    (CaptureState.recording, nil, false, false),
    (.baselining, nil, false, false),
    (.queued, nil, false, false),
    (.notRecording, "root-missing", false, false),
    (.notRecording, nil, false, false),
    (.unknown("hibernating"), nil, false, false),
    (.stopped, "detached", false, true),
    (.stopped, "archived", true, false),
    (.stopped, "maintenance", true, false),
    (.stopped, "root-missing", true, false),
    (.stopped, "watcher-failed", true, false),
    (.stopped, nil, true, false),
  ] as [(CaptureState, String?, Bool, Bool)])
  func onlyStopsThatAreNotAPauseAreInactive(state: CaptureState, reason: String?, isInactive: Bool, isPaused: Bool) {
    expectNoDifference(Self.status(state, reason: reason).isInactive, isInactive)
    expectNoDifference(Self.status(state, reason: reason).isPaused, isPaused)
  }

  @Test func aWorkspaceIsPausedOnlyWhenTheStateWasRead() {
    let detached = CaptureSummary(sessionID: "s", root: "/work/nairobi", state: .stopped, reason: "detached")
    #expect(!CaptureStatus(availability: .loading, capture: detached).isPaused)
    #expect(!CaptureStatus(availability: .failed, capture: detached).isPaused)
    #expect(!CaptureStatus(availability: .available(checkedAt: Self.checkedAt), capture: nil).isPaused)
  }

  @Test func aWorkspaceIsInactiveWithoutACaptureOnlyWhenTheStateWasRead() {
    #expect(CaptureStatus(availability: .available(checkedAt: Self.checkedAt), capture: nil).isInactive)
    #expect(!CaptureStatus(availability: .loading, capture: nil).isInactive)
    #expect(!CaptureStatus(availability: .failed, capture: nil).isInactive)
    #expect(!CaptureStatus(availability: .unavailableFromReader, capture: nil).isInactive)
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
    #expect(Self.status(.recording, binding: Self.linked).askNotice(agentConnection: .connected, route: .outside) == nil)
  }

  @Test func askNoticeFollowsThePrecedence() {
    let unknown = "Capture state is unknown, so questions are disabled. Press ⌘R to check again."
    let notRecording = "This workspace isn't recording, so its chat can't receive questions."
    let noChat = "No chat is connected yet. Send a message in a chat tab to connect it."
    let waiting = "The agent chat hasn't confirmed it can answer yet. It confirms on its next tool call after `slipstream attach`."

    expectNoDifference(
      CaptureStatus(availability: .failed, capture: nil).askNotice(agentConnection: .connected, route: .outside), unknown)
    expectNoDifference(
      CaptureStatus(availability: .unavailableFromReader, capture: nil).askNotice(agentConnection: .connected, route: .outside), unknown)
    expectNoDifference(
      CaptureStatus(availability: .loading, capture: nil).askNotice(agentConnection: .connected, route: .outside), unknown)
    expectNoDifference(Self.status(.unknown("hibernating")).askNotice(agentConnection: .connected, route: .outside), unknown)
    expectNoDifference(
      Self.status(.stopped, reason: "archived", binding: CaptureBinding(generation: "1", state: .unknown("paused")))
        .askNotice(agentConnection: .connected, route: .outside),
      unknown)
    expectNoDifference(
      CaptureStatus(availability: .available(checkedAt: Self.checkedAt), capture: nil)
        .askNotice(agentConnection: .connected, route: .outside),
      notRecording)
    expectNoDifference(
      Self.status(.stopped, reason: "archived", binding: Self.linked).askNotice(agentConnection: .connected, route: .outside),
      notRecording)
    expectNoDifference(Self.status(.recording).askNotice(agentConnection: .connected, route: .outside), noChat)
    expectNoDifference(
      Self.status(.recording, binding: CaptureBinding(generation: "1", state: .unlinked))
        .askNotice(agentConnection: .connected, route: .outside),
      noChat)
    expectNoDifference(
      Self.status(.recording, binding: CaptureBinding(generation: "1", state: .unavailable, reason: "transcript-missing"))
        .askNotice(agentConnection: .connected, route: .outside),
      "The linked chat is unavailable (chat transcript missing), so questions are disabled.")
    expectNoDifference(
      Self.status(.recording, binding: CaptureBinding(generation: "1", state: .setupPending))
        .askNotice(agentConnection: .connected, route: .outside),
      waiting)
    expectNoDifference(Self.status(.recording, binding: Self.linked).askNotice(agentConnection: .setupPending, route: .outside), waiting)
    expectNoDifference(Self.status(.recording, binding: Self.linked).askNotice(agentConnection: .unreported, route: .outside), waiting)
  }

  @Test func askNoticeAppTabWithMessageIsReady() {
    let notice = Self.status(.recording, binding: Self.linked).askNotice(agentConnection: .unreported, route: .app)

    expectNoDifference(notice, nil)
  }

  @Test func askNoticeAppTabSetupPendingIsStillReady() {
    let notice = Self.status(.recording, binding: CaptureBinding(generation: "1", state: .setupPending))
      .askNotice(agentConnection: .setupPending, route: .app)

    expectNoDifference(notice, nil)
  }

  @Test func askNoticeAppTabWithoutMessageIsNothingConnected() {
    let notice = Self.status(.recording, binding: Self.linked).askNotice(agentConnection: .connected, route: .none)

    expectNoDifference(notice, "No chat is connected yet. Send a message in a chat tab to connect it.")
  }

  @Test func askNoticeOutsideChatUnchanged() {
    let notice = Self.status(.recording, binding: CaptureBinding(generation: "1", state: .setupPending))
      .askNotice(agentConnection: .connected, route: .outside)

    expectNoDifference(
      notice,
      "The agent chat hasn't confirmed it can answer yet. It confirms on its next tool call after `slipstream attach`.")
  }

  @Test func askNoticeAppTabStillNeedsRecording() {
    let notice = Self.status(.stopped, reason: "archived", binding: Self.linked)
      .askNotice(agentConnection: .connected, route: .app)

    expectNoDifference(notice, "This workspace isn't recording, so its chat can't receive questions.")
  }

  @Test(arguments: [AskRoute.app, .outside, .none])
  func askNoticeForAPausedWorkspaceOffersRecord(route: AskRoute) {
    let notice = Self.status(.stopped, reason: "detached").askNotice(agentConnection: .connected, route: route)

    expectNoDifference(notice, "This workspace is paused, so its chat can't receive questions. Record it to ask.")
  }
}
