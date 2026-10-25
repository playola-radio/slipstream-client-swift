import Foundation
import SlipstreamCore

enum CaptureAvailability: Equatable, Sendable {
  case loading
  case available(checkedAt: Date)
  case unavailableFromReader
  case failed
}

enum CaptureDot: Equatable, Sendable {
  case recording, attention, unknown, linked, noChat
}

/// Which chat answers Ask for a folder: an app tab that has sent a message answers at once, a
/// linked app tab that hasn't can't be asked yet, and anything else goes through the daemon.
enum AskRoute: Equatable, Sendable {
  case app(tabID: UUID)
  case outside
  case none
}

struct CaptureStatus: Equatable, Sendable {
  var availability: CaptureAvailability
  var capture: CaptureSummary?

  var captureText: String {
    switch availability {
    case .loading: return "Checking capture state…"
    case .unavailableFromReader: return "Capture state unavailable from this reader"
    case .failed: return "Capture state unknown — couldn't reach Slipstream"
    case .available: break
    }
    guard let capture else { return "Not captured — Slipstream has no capture for this workspace" }
    switch capture.state {
    case .recording: return "Recording"
    case .baselining: return "Preparing — not recording yet"
    case .queued: return "Queued — not recording yet"
    case .stopped: return Self.withReason("Stopped", capture.reason, Self.stoppedReasons)
    case .notRecording: return Self.withReason("Not recording", capture.reason, Self.notRecordingReasons)
    case .unknown(let raw): return "Capture state unknown — unrecognised state “\(raw)”"
    }
  }

  func detailText(timeZone: TimeZone) -> String? {
    guard case .available = availability, let capture else { return nil }
    if let retryAtMs = capture.retryAtMs {
      let date = Date(timeIntervalSince1970: TimeInterval(retryAtMs) / 1000)
      return "Retry scheduled \(Self.format(date, "MMM d HH:mm:ss", timeZone))"
    }
    switch (capture.state, capture.reason) {
    case (.baselining, _):
      return "Taking the first snapshot of this workspace. Changes aren't covered until it finishes."
    case (.queued, _):
      return "Slipstream has accepted this workspace and will start it shortly. Refresh to check again."
    case (.notRecording, "capture-limit-reached"):
      return "Every capture slot is in use. This workspace starts on its own, oldest first, when one frees up. Refresh to check again."
    case (.stopped, "maintenance"):
      return "Slipstream is cleaning up its storage. Capture resumes on its own afterwards. Refresh to check again."
    case (.unknown, _):
      return "Update Slipstream Viewer to read this state."
    default:
      return nil
    }
  }

  func checkedText(timeZone: TimeZone) -> String? {
    guard case .available(let checkedAt) = availability else { return nil }
    return "Checked \(Self.format(checkedAt, "HH:mm:ss", timeZone))"
  }

  var pickerSuffix: String? {
    switch availability {
    case .loading: return nil
    case .unavailableFromReader, .failed: return "State unknown"
    case .available: break
    }
    guard let capture else { return "Not captured" }
    switch capture.state {
    case .recording: return "Recording"
    case .notRecording where capture.reason == "capture-limit-reached": return "Waiting for a free slot"
    case .notRecording: return "Not recording"
    case .queued: return "Queued"
    case .baselining: return "Preparing"
    case .stopped: return "Stopped"
    case .unknown: return "State unknown"
    }
  }

  var isInactive: Bool {
    guard case .available = availability else { return false }
    guard let capture else { return true }
    switch capture.state {
    case .stopped: return true
    case .notRecording: return capture.reason != "capture-limit-reached"
    case .recording, .baselining, .queued, .unknown: return false
    }
  }

  var captureDot: CaptureDot {
    guard case .available = availability, let capture else { return .unknown }
    switch capture.state {
    case .recording: return .recording
    case .unknown: return .unknown
    default: return .attention
    }
  }

  var chatText: String {
    switch chatLink {
    case .checking: "Checking chat link…"
    case .unknown: "Chat-link state unknown"
    case .noChat: "No chat linked"
    case .bound(let binding):
      switch binding.state {
      case .connected: "Linked — changes are possibly the agent's"
      case .setupPending where binding.reason == "config-missing": "Waiting for setup — setup configuration missing"
      case .setupPending: "Waiting for setup — the chat hasn't confirmed it can answer yet"
      case .unavailable: Self.withReason("Unavailable", binding.reason, Self.bindingUnavailableReasons)
      case .unlinked: "No chat linked"
      case .unknown(let raw): "Chat-link state unknown — unrecognised state “\(raw)”"
      }
    }
  }

  var chatDot: CaptureDot {
    switch chatLink {
    case .checking, .unknown: .unknown
    case .noChat: .noChat
    case .bound(let binding):
      switch binding.state {
      case .connected: .linked
      case .setupPending, .unavailable: .attention
      case .unlinked: .noChat
      case .unknown: .unknown
      }
    }
  }

  func askNotice(agentConnection: AgentConnection, route: AskRoute) -> String? {
    guard case .available = availability else { return Self.unknownNotice }
    if case .unknown = capture?.state { return Self.unknownNotice }
    if case .unknown = capture?.binding?.state { return Self.unknownNotice }
    guard let capture, capture.state == .recording else {
      return "This workspace isn't recording, so its chat can't receive questions."
    }
    switch route {
    case .app: return nil
    case .none: return Self.nothingConnectedNotice
    case .outside: break
    }
    guard let binding = capture.binding, binding.state != .unlinked else { return Self.nothingConnectedNotice }
    if binding.state == .unavailable {
      let reason = binding.reason.map { " (\(Self.wording($0, Self.bindingUnavailableReasons)))" } ?? ""
      return "The linked chat is unavailable\(reason), so questions are disabled."
    }
    guard binding.state == .connected, agentConnection == .connected else {
      return "The agent chat hasn't confirmed it can answer yet. It confirms on its next tool call after `slipstream attach`."
    }
    return nil
  }

  private enum ChatLink {
    case checking, unknown, noChat
    case bound(CaptureBinding)
  }

  private var chatLink: ChatLink {
    switch availability {
    case .loading: return .checking
    case .unavailableFromReader, .failed: return .unknown
    case .available: break
    }
    guard let capture else { return .noChat }
    if case .unknown = capture.state { return .unknown }
    if capture.state == .notRecording, capture.reason == "daemon-unavailable" { return .unknown }
    guard let binding = capture.binding else { return .noChat }
    return .bound(binding)
  }

  private static let unknownNotice = "Capture state is unknown, so questions are disabled. Refresh to check again."
  private static let nothingConnectedNotice = "No chat is connected yet. Send a message in a chat tab to connect it."

  private static let stoppedReasons = [
    "detached": "capture detached",
    "archived": "workspace archived",
    "maintenance": "maintenance in progress",
    "root-missing": "workspace folder missing or replaced",
    "watcher-failed": "file watcher failed",
  ]

  private static let notRecordingReasons = [
    "capture-limit-reached": "waiting for a free capture slot",
    "daemon-unavailable": "Slipstream stopped reporting on this capture",
    "root-overlap": "folder overlaps another capture",
    "root-missing": "workspace folder missing or replaced",
    "baseline-failed": "first snapshot failed",
    "storage-unavailable": "storage unavailable",
    "watcher-failed": "file watcher failed",
    "resume-failed": "capture couldn't resume",
    "resource-limit": "system resource limit reached",
    "stop-unconfirmed": "stop couldn't be confirmed",
  ]

  private static let bindingUnavailableReasons = [
    "transcript-missing": "chat transcript missing",
    "transcript-unreadable": "chat transcript unreadable",
    "identity-changed": "chat identity changed",
    "runtime-unsupported": "agent runtime unsupported",
  ]

  private static func withReason(_ state: String, _ reason: String?, _ wordings: [String: String]) -> String {
    guard let reason else { return state }
    return "\(state) — \(wording(reason, wordings))"
  }

  private static func wording(_ reason: String, _ wordings: [String: String]) -> String {
    wordings[reason] ?? "unrecognised reason “\(reason)”"
  }

  private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = pattern
    return formatter.string(from: date)
  }
}
