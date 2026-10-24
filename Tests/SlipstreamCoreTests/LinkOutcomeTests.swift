import CustomDump
import Testing

@testable import SlipstreamCore

struct LinkOutcomeTests {
  @Test func attachSuccess() {
    let output = """
      Installed the Slipstream question hook in /w/.claude/settings.local.json
      Recording /w; agent setup pending.
      session_id: 6f3c1e0a-1111-4222-8333-444455556666
      agent_connection: setup_pending
      """
    expectNoDifference(LinkOutcome.attach(exitCode: 0, output: output), .linked)
  }

  @Test func attachTranscriptStillBeingWrittenRetries() {
    let output = "slipstream: this chat's transcript is still being written; run `slipstream attach` again after the next tool call. Nothing was recorded.\n"
    expectNoDifference(LinkOutcome.attach(exitCode: 1, output: output), .retryLater)
  }

  @Test func attachDaemonHeadNotCompleteRetries() {
    let output = "slipstream: IDENTITY_UNRESOLVED: root Claude transcript head is not complete yet; try again after the next tool call\n"
    expectNoDifference(LinkOutcome.attach(exitCode: 1, output: output), .retryLater)
  }

  @Test func attachExit3Retries() {
    let output = "slipstream: the capture of /w is still pending, outcome unknown (session 6f3c). Check with `slipstream status 6f3c`; running this command again does not start a second capture.\n"
    expectNoDifference(LinkOutcome.attach(exitCode: 3, output: output), .retryLater)
  }

  @Test func attachSlotsFull() {
    let output = "slipstream: BINDING_LIMIT_REACHED: 10 of 10 agent bindings are in use\n"
    expectNoDifference(LinkOutcome.attach(exitCode: 1, output: output), .refused(.slotsFull))
  }

  @Test func attachBindingExistsSkips() {
    let output = "slipstream: BINDING_EXISTS: /w is already linked to another chat\n"
    expectNoDifference(LinkOutcome.attach(exitCode: 1, output: output), .skipped)
  }

  @Test func attachOldCLIVersionRefusal() {
    let output = "slipstream: this Claude chat's version or launch mode is not a runtime Slipstream has verified, or its transcript does not match /w. Questions could not be delivered reliably, so nothing was installed or recorded.\n"
    expectNoDifference(LinkOutcome.attach(exitCode: 1, output: output), .refused(.slipstreamTooOld))
  }

  @Test func attachOldDaemonVersionRefusal() {
    let output = "slipstream: IDENTITY_UNRESOLVED: root Claude transcript identity is unsupported-version\n"
    expectNoDifference(LinkOutcome.attach(exitCode: 1, output: output), .refused(.slipstreamTooOld))
  }

  @Test func attachSetupIncompleteKeepsMessage() {
    let message = "The workspace is recording and this chat is linked, but setup is incomplete. claude mcp add exited 1. Fix the setup error, then run `slipstream attach` again from this chat."
    let output = "session_id: 6f3c\nagent_connection: setup_pending\nslipstream: \(message)\n"
    expectNoDifference(LinkOutcome.attach(exitCode: 1, output: output), .refused(.setupIncomplete(message)))
  }

  @Test func attachOtherKeepsLastSlipstreamLine() {
    let output = "slipstream: an earlier warning\nnoise from a hook\nslipstream: STORE_LOCKED: the store is locked\ntrailing noise\n"
    expectNoDifference(
      LinkOutcome.attach(exitCode: 1, output: output), .refused(.other("STORE_LOCKED: the store is locked")))
  }

  @Test func attachWithoutSlipstreamLineKeepsExitStatus() {
    expectNoDifference(
      LinkOutcome.attach(exitCode: 2, output: "Usage: slipstream attach [dir]\n"),
      .refused(.other("slipstream exited with status 2.")))
  }

  @Test func unlinkOnline() {
    let output = "session_id: 6f3c1e0a-1111-4222-8333-444455556666\nbinding_generation: 3\n"
    expectNoDifference(LinkOutcome.unlink(exitCode: 0, output: output), .unlinked)
  }

  @Test func unlinkAlreadyUnlinked() {
    let output = "session_id: 6f3c1e0a-1111-4222-8333-444455556666\nalready_unlinked: true\n"
    expectNoDifference(LinkOutcome.unlink(exitCode: 0, output: output), .unlinked)
  }

  @Test func unlinkOfflineExit0() {
    let output = "slipstream: no daemon is running; the unlink is recorded and the chat will not be reconnected.\n"
    expectNoDifference(LinkOutcome.unlink(exitCode: 0, output: output), .unlinked)
  }

  @Test func unlinkErrorIsOther() {
    let output = "slipstream: SESSION_NOT_FOUND: no capture 6f3c\n"
    expectNoDifference(
      LinkOutcome.unlink(exitCode: 1, output: output), .refused(.other("SESSION_NOT_FOUND: no capture 6f3c")))
  }

  @Test func attachOutputCutToLast64KiBStillParses() {
    let filler = String(repeating: "x", count: 100)
    let lines = (0..<700).map { "hook output \($0) \(filler)" }.joined(separator: "\n")
    let full = "slipstream: the very first line\n\(lines)\nslipstream: BINDING_LIMIT_REACHED: 10 of 10 agent bindings are in use\n"
    let tail = String(decoding: Array(full.utf8).suffix(65_536), as: UTF8.self)
    #expect(!tail.contains("the very first line"))
    expectNoDifference(LinkOutcome.attach(exitCode: 1, output: tail), .refused(.slotsFull))
  }
}
