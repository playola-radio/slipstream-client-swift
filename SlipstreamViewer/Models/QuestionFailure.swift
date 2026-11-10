import SlipstreamCore

enum QuestionFailure {
  static func isOutcomeUnknown(_ error: any Error) -> Bool {
    switch error {
    case QuestionError.unavailable: false
    case QuestionError.rejected(let code, _): code == "STORAGE_UNAVAILABLE"
    default: true
    }
  }

  static func reason(_ error: any Error) -> String {
    switch error {
    case QuestionError.unavailable:
      "The question service isn't available. Attach the agent session through the shared daemon, then retry."
    case QuestionError.rejected(let code, let message):
      daemonSaid(message, after: failureText(code))
    default: "The daemon's response wasn't received or couldn't be verified."
    }
  }

  static func message(_ error: any Error, hasUncertainSubmission: Bool) -> String {
    reason(error) + (hasUncertainSubmission
      ? " An earlier submission may already be queued. Retry unchanged to reuse its request ID. Editing sends a separate question."
      : " Your draft is kept.")
  }

  static func daemonSaid(_ message: String, after text: String) -> String {
    let said = DiagnosticText.line(message)
    guard !said.isEmpty, said != text else { return text }
    return text + " The daemon said: " + said + (said.hasSuffix(".") ? "" : ".")
  }

  private static func failureText(_ code: String) -> String {
    switch code {
    case "SESSION_NOT_SELECTED": "This capture is no longer attached to the agent. The question stays bound to its original capture."
    case "AGENT_NOT_CONNECTED": "The agent chat for this capture hasn't confirmed it can answer. Run `slipstream attach` inside that chat. The question stays bound to its original capture."
    case "STALE_BINDING": "This workspace's chat was relinked after the app last checked. Press ⌘R to see which chat is linked now, then ask again."
    case "CAPTURE_NOT_READY": "The capture isn't ready to accept questions. Try again shortly."
    case "INVALID_CONTEXT": "This source selection couldn't be verified. Select up to 200 lines totaling at most 16 KiB from an available snapshot."
    case "INVALID_QUESTION": "Use a nonempty question of at most 8192 UTF-8 bytes."
    case "QUESTION_LIMIT": "The question queue is full. Try again later."
    case "STORAGE_UNAVAILABLE": "The daemon couldn't confirm storage of this question."
    case "REQUEST_CONFLICT": "This request ID already belongs to a different question."
    default: "This question couldn't be accepted (\(code))."
    }
  }
}
