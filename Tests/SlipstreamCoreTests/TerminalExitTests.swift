import CustomDump
import SlipstreamCore
import Testing

struct TerminalExitTests {
  @Test func zeroStatusIsCleanExit() {
    expectNoDifference(TerminalExit(waitStatus: 0), .exited(0))
  }

  @Test func exitCodeLivesInTheSecondByte() {
    expectNoDifference(TerminalExit(waitStatus: 256), .exited(1))
  }

  @Test func killSignalIsSignalled() {
    expectNoDifference(TerminalExit(waitStatus: 9), .signalled(9))
  }

  @Test func termSignalIsSignalled() {
    expectNoDifference(TerminalExit(waitStatus: 15), .signalled(15))
  }

  @Test func exitNoteShowsTheCode() {
    expectNoDifference(TerminalExit.exited(1).noteText, "Process exited (exit 1)")
  }

  @Test func signalNoteShowsTheName() {
    expectNoDifference(TerminalExit.signalled(15).noteText, "Process exited (signal SIGTERM)")
  }
}
