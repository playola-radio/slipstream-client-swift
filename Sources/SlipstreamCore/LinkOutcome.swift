/// The result of one link operation, parsed from the exit code and merged output of its last
/// `slipstream attach` or `slipstream unlink` run.
public enum LinkOutcome: Equatable, Sendable {
  case linked
  case unlinked
  /// The binding was not what the caller expected, so nothing changed.
  case skipped
  case retryLater
  case refused(LinkRefusal)
}

public enum LinkRefusal: Equatable, Sendable {
  case slipstreamTooOld
  case slotsFull
  /// The chat is linked, but installing the hook or answer tool failed.
  case setupIncomplete(String)
  case other(String)
}

extension LinkOutcome {
  public static func attach(exitCode: Int32, output: String) -> LinkOutcome {
    switch exitCode {
    case 0: return .linked
    case 3: return .retryLater
    default: break
    }
    guard let message = lastMessage(output) else { return .refused(.other(exitText(exitCode))) }
    if message.contains("transcript is still being written")
      || message.contains("root Claude transcript head is not complete yet")
    {
      return .retryLater
    }
    if message.hasPrefix("BINDING_LIMIT_REACHED:") { return .refused(.slotsFull) }
    if message.hasPrefix("BINDING_EXISTS:") { return .skipped }
    if message.contains("is not a runtime Slipstream has verified")
      || message.contains("root Claude transcript identity is unsupported-version")
    {
      return .refused(.slipstreamTooOld)
    }
    if message.contains("this chat is linked, but setup is incomplete") {
      return .refused(.setupIncomplete(message))
    }
    return .refused(.other(message))
  }

  public static func unlink(exitCode: Int32, output: String) -> LinkOutcome {
    guard exitCode != 0 else { return .unlinked }
    return .refused(.other(lastMessage(output) ?? exitText(exitCode)))
  }

  private static let prefix = "slipstream: "

  private static func lastMessage(_ output: String) -> String? {
    output.split(whereSeparator: \.isNewline).last { $0.hasPrefix(prefix) }
      .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
  }

  private static func exitText(_ exitCode: Int32) -> String {
    "slipstream exited with status \(exitCode)."
  }
}
