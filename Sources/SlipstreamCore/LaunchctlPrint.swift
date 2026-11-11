public struct LaunchdJob: Equatable, Sendable {
  public let pid: Int32?
  public let lastExit: String?
  public let raw: String

  public init(pid: Int32?, lastExit: String?, raw: String) {
    self.pid = pid
    self.lastExit = lastExit
    self.raw = raw
  }
}

public enum LaunchctlPrint {
  public static func job(in output: String) -> LaunchdJob {
    var pid: Int32?
    var lastExit: String?
    // Only the service's own properties: nested blocks (coalitions, environment) have deeper indents.
    for line in output.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
      let parts = line.dropFirst().split(separator: " = ", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      switch parts[0] {
      case "pid": pid = Int32(parts[1])
      case "last exit code" where parts[1] != "(never exited)": lastExit = parts[1]
      default: break
      }
    }
    return LaunchdJob(pid: pid, lastExit: lastExit, raw: output)
  }
}
