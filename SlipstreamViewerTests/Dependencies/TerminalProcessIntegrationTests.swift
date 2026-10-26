import ConcurrencyExtras
import CustomDump
import Darwin
import Foundation
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@Suite(.serialized)
final class TerminalProcessIntegrationTests {
  let folder = FileManager.default.temporaryDirectory.appending(path: "terminal-process-\(UUID().uuidString)")

  init() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: folder)
  }

  @Test func exitZero() async throws {
    let recorder = try launch("exit 0")

    try await recorder.waitForEnd()

    expectNoDifference(recorder.events.value.last, .finished(.exited(0)))
  }

  @Test func exitOne() async throws {
    let recorder = try launch("exit 1")

    try await recorder.waitForEnd()

    expectNoDifference(recorder.events.value.last, .finished(.exited(1)))
  }

  @Test func signalled() async throws {
    let recorder = try launch("kill -TERM $$")

    try await recorder.waitForEnd()

    expectNoDifference(recorder.events.value.last, .finished(.signalled(SIGTERM)))
  }

  @Test func immediateExitKeepsOutput() async throws {
    let recorder = try launch(#"printf 'a%.0s' $(seq 1 20000); printf "\nworkspace_path: /x\n""#)

    try await recorder.waitForEnd()

    expectNoDifference(recorder.text, String(repeating: "a", count: 20_000) + "\r\nworkspace_path: /x\r\n")
    expectNoDifference(recorder.events.value.last, .finished(.exited(0)))
  }

  @Test func launchFailureThrows() throws {
    #expect(throws: TerminalLaunchError.self) {
      _ = try TerminalRuntimeClient.liveValue.launch(self.launchSettings([], executable: "/no/such/shell"))
    }
    #expect(throws: TerminalLaunchError.self) {
      var settings = self.launchSettings([])
      settings.directory = self.folder.appending(path: "missing").path
      _ = try TerminalRuntimeClient.liveValue.launch(settings)
    }
    let locked = folder.appending(path: "locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path)
    #expect(throws: TerminalLaunchError.self) {
      var settings = self.launchSettings([])
      settings.directory = locked.path
      _ = try TerminalRuntimeClient.liveValue.launch(settings)
    }
  }

  @Test func idleShellIsNotBusy() async throws {
    let recorder = try await launchInteractiveShell()

    #expect(recorder.handle.isBusy() == false)
    await recorder.handle.stop()
  }

  @Test func foregroundProgramIsBusy() async throws {
    let recorder = try await launchInteractiveShell()

    recorder.handle.write(Array("sleep 30\n".utf8))

    try await withTimeout(.seconds(2)) {
      while !recorder.handle.isBusy() { try await Task.sleep(for: .milliseconds(10)) }
    }
    await recorder.handle.stop()
  }

  @Test func stopEndsAShellThatIgnoresHangup() async throws {
    let recorder = try launch("trap '' HUP TERM; echo pid=$$; sleep 100")
    try await recorder.waitForText { $0.contains("pid=") && $0.hasSuffix("\r\n") }
    let pid = try #require(Int32(recorder.text.split(separator: "=")[1].trimmingCharacters(in: .whitespacesAndNewlines)))

    let started = ContinuousClock.now
    try await withTimeout(.seconds(4)) { await recorder.handle.stop() }

    #expect(ContinuousClock.now - started >= .seconds(TerminalProcess.hangupGrace))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }

  @Test func stopTwiceIsSafe() async throws {
    let recorder = try launch("sleep 100")

    async let first: Void = recorder.handle.stop()
    async let second: Void = recorder.handle.stop()
    _ = await (first, second)
    await recorder.handle.stop()

    try await recorder.waitForEnd()
    expectNoDifference(recorder.events.value.last, .finished(.signalled(SIGHUP)))
  }

  @Test func exitedProcessIsReapedWithoutStop() async throws {
    let recorder = try launch("echo pid=$$")

    try await recorder.waitForEnd()

    let pid = try #require(Int32(recorder.text.split(separator: "=")[1].trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }

  @Test func stopKeepsOutputPrintedOnHangup() async throws {
    let recorder = try launch(#"trap 'printf "bye%.0s" $(seq 1 5000); exit 0' HUP; echo ready; sleep 100 & wait"#)
    try await recorder.waitForText { $0.contains("ready\r\n") }

    await recorder.handle.stop()

    try await recorder.waitForEnd()
    #expect(recorder.text.hasSuffix(String(repeating: "bye", count: 5000)))
    expectNoDifference(recorder.events.value.last, .finished(.exited(0)))
  }

  @Test func unreadOutputPausesTheProgram() async throws {
    let marker = folder.appending(path: "done")
    let byteCount = TerminalProcess.bufferLimit * 4
    let handle = try TerminalRuntimeClient.liveValue.launch(
      launchSettings(["-c", "head -c \(byteCount) /dev/zero; touch '\(marker.path)'"]))

    await #expect(throws: TimedOut.self) {
      try await withTimeout(.milliseconds(500)) {
        while !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(10)) }
      }
    }

    let recorder = Recorder(handle)
    try await recorder.waitForEnd()
    #expect(recorder.text.utf8.count == byteCount)
    expectNoDifference(recorder.events.value.last, .finished(.exited(0)))
  }

  @Test func writeReachesTheChild() async throws {
    let recorder = try launch("stty -echo; echo ready; cat")
    try await recorder.waitForText { $0.contains("ready\r\n") }

    recorder.handle.write(Array("hello\n".utf8))

    try await recorder.waitForText { $0.hasSuffix("ready\r\nhello\r\n") }
    await recorder.handle.stop()
  }

  @Test func resizeIsSeen() async throws {
    let recorder = try launch("stty -echo; echo ready; read line; stty size")
    try await recorder.waitForText { $0.contains("ready\r\n") }

    recorder.handle.resize(TerminalSize(columns: 100, rows: 30))
    recorder.handle.write(Array("\n".utf8))

    try await recorder.waitForEnd()
    expectNoDifference(recorder.text, "ready\r\n30 100\r\n")
  }

  private func launchSettings(_ arguments: [String], executable: String = "/bin/sh") -> TerminalLaunch {
    TerminalLaunch(
      executable: executable,
      arguments: arguments,
      environment: ["PATH": "/usr/bin:/bin", "HOME": folder.path, "TERM": "xterm-256color"],
      directory: folder.path,
      size: TerminalSize(columns: 80, rows: 24)
    )
  }

  private func launch(_ script: String) throws -> Recorder {
    Recorder(try TerminalRuntimeClient.liveValue.launch(launchSettings(["-c", script])))
  }

  private func launchInteractiveShell() async throws -> Recorder {
    var settings = launchSettings(["-i"])
    settings.environment["PS1"] = "ready$ "
    let recorder = Recorder(try TerminalRuntimeClient.liveValue.launch(settings))
    try await recorder.waitForText { $0.hasSuffix("ready$ ") }
    return recorder
  }
}

private final class Recorder: Sendable {
  let handle: TerminalProcessHandle
  let events = LockIsolated<[TerminalEvent]>([])
  private let reading: Task<Void, Never>

  init(_ handle: TerminalProcessHandle) {
    self.handle = handle
    let events = events
    reading = Task {
      for await event in handle.events { events.withValue { $0.append(event) } }
    }
  }

  var text: String {
    let bytes = events.value.flatMap { event -> [UInt8] in
      if case .output(let bytes) = event { bytes } else { [] }
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  func waitForEnd() async throws {
    try await withTimeout(.seconds(10)) { await self.reading.value }
  }

  func waitForText(_ isReady: @escaping @Sendable (String) -> Bool) async throws {
    try await withTimeout(.seconds(10)) {
      while !isReady(self.text) { try await Task.sleep(for: .milliseconds(10)) }
    }
  }
}
