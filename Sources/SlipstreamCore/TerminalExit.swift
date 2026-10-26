import Foundation

public enum TerminalExit: Equatable, Sendable {
  case exited(Int32)
  case signalled(Int32)

  private static let signalNames: [Int32: String] = [
    SIGHUP: "SIGHUP",
    SIGINT: "SIGINT",
    SIGQUIT: "SIGQUIT",
    SIGABRT: "SIGABRT",
    SIGKILL: "SIGKILL",
    SIGSEGV: "SIGSEGV",
    SIGPIPE: "SIGPIPE",
    SIGTERM: "SIGTERM",
  ]

  public init(waitStatus: Int32) {
    if waitStatus & 0x7f == 0 {
      self = .exited((waitStatus >> 8) & 0xff)
    } else {
      self = .signalled(waitStatus & 0x7f)
    }
  }

  public var noteText: String {
    switch self {
    case .exited(let code):
      "Process exited (exit \(code))"
    case .signalled(let number):
      "Process exited (signal \(Self.signalNames[number] ?? "\(number)"))"
    }
  }
}
