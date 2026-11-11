import Foundation
import SlipstreamCore

struct RecorderMessage: Equatable {
  enum Icon: Equatable {
    case starting
    case restarting
    case warning
    case failure
  }

  enum Tone: Equatable {
    case neutral
    case warning
    case error
  }

  enum Action: Equatable, Hashable {
    case tryAgain
    case replaceIt
    case openLogFile

    var title: String {
      switch self {
      case .tryAgain: "Try again"
      case .replaceIt: "Replace it"
      case .openLogFile: "Open log file"
      }
    }
  }

  var icon: Icon
  var tone: Tone
  var headline: String
  var footer: String
  var evidence: Evidence?
  var actions: [Action]

  var dockedActions: [Action] { actions }

  func isPrimary(_ action: Action) -> Bool { action == actions.first }

  init(icon: Icon, tone: Tone, headline: String, footer: String, evidence: Evidence?, actions: [Action]) {
    self.icon = icon
    self.tone = tone
    self.headline = headline
    self.footer = footer
    self.evidence = evidence
    self.actions = actions
  }

  init?(state: RecorderState, store: String, replaceIsAvailable: Bool) {
    switch state {
    case .running, .external:
      return nil

    case let .starting(bundled):
      let text = "Starting the recorder \(Self.describe(bundled))…"
      self.init(icon: .starting, tone: .neutral, headline: text, footer: text, evidence: nil, actions: [])

    case let .restarting(from, to):
      let text = "Restarting the recorder \(from) → \(Self.describe(to))… changes resume when it's back"
      self.init(icon: .restarting, tone: .neutral, headline: text, footer: text, evidence: nil, actions: [])

    case let .updateDidntFinish(running, bundled, failure, evidence):
      let new = bundled.version
      let old = running.version
      let (headline, footer) =
        switch failure {
        case let .mismatch(what):
          (
            "The copy of recorder \(new) didn't match the one signed into the app, so the app kept recorder \(old) running.",
            "Recorder \(old) still running · copy of \(new) didn't match the app (\(what))"
          )
        case .copy:
          (
            "Recorder \(new) couldn't be copied out of the app, so the app kept recorder \(old) running.",
            "Recorder \(old) still running · copy of \(new) didn't finish"
          )
        case .switchCurrent:
          (
            "The app couldn't switch to recorder \(new), so it kept recorder \(old) running.",
            "Recorder \(old) still running · couldn't switch to \(new)"
          )
        }
      self.init(
        icon: .warning, tone: .warning, headline: headline, footer: footer, evidence: evidence, actions: [.tryAgain])

    case let .anotherRecorder(pid, running, bundled, evidence):
      let who = running.build.map { "recorder \(running.version) (build \($0.prefix(8)))" } ?? "npm \(running.version)"
      let path = (store as NSString).abbreviatingWithTildeInPath
      let (headline, footer) =
        if running.isNewer(than: bundled) {
          (
            "A recorder newer than this app's \(bundled.version) (pid \(pid), \(who)) is using \(path). "
              + "It's still recording; update Slipstream so the app can switch to its own recorder.",
            "Recorder pid \(pid) is \(who), newer than this app's \(bundled.version)"
          )
        } else {
          (
            "A recorder this app didn't start (pid \(pid), \(who)) is using \(path). "
              + (replaceIsAvailable
                ? "It's still recording; the app won't stop it unless you replace it."
                : "It's still recording; the app won't stop it."),
            "Recorder pid \(pid) is \(who), not started by this app"
          )
        }
      self.init(
        icon: .warning, tone: .warning, headline: headline, footer: footer,
        evidence: evidence, actions: replaceIsAvailable ? [.replaceIt] : [])

    case let .wontStart(bundled, failure, evidence):
      let name = bundled.map { "Recorder \($0.version)" } ?? "The recorder"
      let version = bundled?.version ?? ""
      let text =
        switch failure {
        case .unreadableBundle: "The recorder inside Slipstream.app couldn't be read."
        case .copy: "\(name) couldn't be copied out of Slipstream.app, and no recorder is running."
        case .probe: "The app couldn't check whether a recorder is running."
        case .switchCurrent: "The app couldn't switch to recorder \(version), and no recorder is running."
        case let .stop(pid): "The app couldn't stop recorder pid \(pid) to switch to \(version)."
        case .serviceInstall(nil): "\(name) didn't start: slipstream service install couldn't run."
        case let .serviceInstall(code?): "\(name) didn't start: slipstream service install exited with code \(code)."
        case let .exited(code): "\(name) exited with code \(code) before it was ready."
        }
      let actions: [Action] =
        switch failure {
        case .serviceInstall, .exited: [.tryAgain, .openLogFile]
        default: [.tryAgain]
        }
      self.init(icon: .failure, tone: .error, headline: text, footer: text, evidence: evidence, actions: actions)

    case let .migrationIncomplete(bundled, failure, evidence):
      var parts: [String] = []
      switch failure.links.count {
      case 0: break
      case 1: parts.append("the \(failure.links[0]) command link")
      case let count: parts.append("\(count) command links")
      }
      if failure.adoptFailed { parts.append("the agent hooks") }
      let count = failure.links.count + (failure.adoptFailed ? 1 : 0)
      let changes = count == 1 ? "1 setup change" : "\(count) setup changes"
      let verb = count == 1 && !failure.adoptFailed ? "points" : "point"
      let text =
        "Recorder \(bundled.version) is running, but \(changes) didn't finish: "
        + "\(parts.joined(separator: " and ")) still \(verb) at the old npm install."
      self.init(icon: .warning, tone: .warning, headline: text, footer: text, evidence: evidence, actions: [.tryAgain])
    }
  }

  private static func describe(_ identity: RuntimeIdentity) -> String {
    "\(identity.version) (build \(identity.build.prefix(8)))"
  }
}
