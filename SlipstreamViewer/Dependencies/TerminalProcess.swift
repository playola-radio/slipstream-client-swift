import Darwin
import Foundation
import SlipstreamCore
import SwiftTerm
import Synchronization

/// A shell or command in a pseudo-terminal, leading its own session, so its pid is also its
/// process group id.
///
/// `.finished` is the last event. It is sent once the process has exited and the terminal's
/// output has been read to the end, or `outputGrace` after the exit if something the process
/// left behind still holds the terminal open.
///
/// The exited process stays a zombie until `stop` reaps it, so its pid, and with it the process
/// group id, can't be reused by an unrelated process while `stop` is signalling.
final class TerminalProcess: Sendable {
  static let hangupGrace = 2.0
  static let outputGrace = 1.0
  private static let forkLock = Mutex(())

  let events: AsyncStream<TerminalEvent>
  private let pid: pid_t
  private let continuation: AsyncStream<TerminalEvent>.Continuation
  /// nil once closed. Writes, resizes and busy checks hold the lock, so they never touch a
  /// descriptor number the system has since handed out again.
  private let master: Mutex<Int32?>
  private let reader: any DispatchSourceRead
  private let writer = DispatchQueue(label: "TerminalProcess.write")
  private let state = Mutex(State())
  private let exited = OneShot()
  private let finished = OneShot()
  private let isStopping = Mutex(false)

  private struct State {
    var exit: TerminalExit?
    var isDrained = false
    var isFinished = false
  }

  init(_ launch: TerminalLaunch) throws {
    guard FileManager.default.isExecutableFile(atPath: launch.executable) else {
      throw TerminalLaunchError(text: "Couldn't find \(launch.executable)")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: launch.directory, isDirectory: &isDirectory), isDirectory.boolValue
    else { throw TerminalLaunchError(text: "The folder \(launch.directory) doesn't exist") }

    var size = winsize(launch.size)
    var environment = launch.environment
    environment["PWD"] = launch.directory
    let variables = environment.map { "\($0.key)=\($0.value)" }
    let child = Self.forkLock.withLock { _ -> (pid: pid_t, masterFd: Int32)? in
      // Dispatch threads block most signals and the child keeps the mask through exec, which
      // would leave the shell deaf to hangups and Ctrl-C. Fork with nothing blocked.
      var noSignals = sigset_t()
      var previous = sigset_t()
      sigemptyset(&noSignals)
      pthread_sigmask(SIG_SETMASK, &noSignals, &previous)
      defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
      guard
        let child = PseudoTerminalHelpers.fork(
          andExec: launch.executable, args: [launch.executable] + launch.arguments, env: variables,
          currentDirectory: launch.directory, desiredWindowSize: &size)
      else { return nil }
      // Before any other launch forks, so no other shell inherits this terminal.
      _ = fcntl(child.masterFd, F_SETFD, FD_CLOEXEC)
      return child
    }
    guard let child else { throw TerminalLaunchError(text: "Couldn't open a terminal for \(launch.executable)") }

    pid = child.pid
    _ = fcntl(child.masterFd, F_SETFL, fcntl(child.masterFd, F_GETFL) | O_NONBLOCK)
    master = Mutex(child.masterFd)
    (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    reader = DispatchSource.makeReadSource(
      fileDescriptor: child.masterFd, queue: DispatchQueue(label: "TerminalProcess.read"))

    reader.setEventHandler { [self] in readAvailable(from: child.masterFd) }
    // Dispatch runs this after the last read, and the descriptor stays open until then.
    reader.setCancelHandler { [self] in
      master.withLock { descriptor in
        if let descriptor { close(descriptor) }
        descriptor = nil
      }
      state.withLock { state in
        state.isDrained = true
        finish(&state)
      }
    }
    reader.activate()
    Thread.detachNewThread { [self] in waitForExit() }
  }

  func write(_ bytes: [UInt8]) {
    writer.async { [self] in
      var offset = 0
      while offset < bytes.count {
        let start = offset
        let result = master.withLock { descriptor -> (count: Int, error: Int32)? in
          guard let descriptor else { return nil }
          let count = bytes[start...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
          return (count, errno)
        }
        guard let result else { return }
        if result.count >= 0 {
          offset += result.count
        } else if result.error == EAGAIN {
          // The terminal's input queue is full until the program reads.
          usleep(10_000)
        } else if result.error != EINTR {
          return
        }
      }
    }
  }

  func resize(_ size: TerminalSize) {
    master.withLock { descriptor in
      guard let descriptor else { return }
      var window = winsize(size)
      _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: descriptor, windowSize: &window)
    }
  }

  /// Whether the shell is running a program in the foreground.
  func isBusy() -> Bool {
    guard state.withLock({ $0.exit == nil }) else { return false }
    return master.withLock { descriptor in
      guard let descriptor else { return false }
      return tcgetpgrp(descriptor) != pid
    }
  }

  /// Hangs up the foreground program and the shell, kills both after `hangupGrace`, closes the
  /// terminal and reaps the shell. Returns once `.finished` has been sent. Safe to call more than
  /// once.
  func stop() async {
    let isFirst = isStopping.withLock { started in
      defer { started = true }
      return !started
    }
    if isFirst {
      signalGroups(SIGHUP)
      signalGroups(SIGCONT)
      await exited.wait(timeout: Self.hangupGrace)
      signalGroups(SIGKILL)
      reader.cancel()
      await exited.wait()
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
    await finished.wait()
  }

  private func signalGroups(_ signal: Int32) {
    let foreground = master.withLock { descriptor in descriptor.map(tcgetpgrp) ?? -1 }
    if foreground > 0 && foreground != pid { kill(-foreground, signal) }
    // Before the child's setsid there is no group yet; the unreaped pid is still ours.
    if kill(-pid, signal) != 0 { kill(pid, signal) }
  }

  private func readAvailable(from descriptor: Int32) {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let count = read(descriptor, &buffer, buffer.count)
    if count > 0 {
      let bytes = Array(buffer[..<count])
      state.withLock { state in
        if !state.isFinished { continuation.yield(.output(bytes)) }
      }
    } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
      // End of output: every holder of the terminal has closed it (EIO on macOS).
      reader.cancel()
    }
  }

  /// Waits without reaping (`WNOWAIT`); `stop` reaps.
  private func waitForExit() {
    var info = siginfo_t()
    while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
    // `waitid` reports a siginfo, so rebuild the wait status from it.
    let waitStatus = info.si_code == CLD_EXITED ? (info.si_status & 0xff) << 8 : info.si_status & 0x7f
    state.withLock { state in
      state.exit = TerminalExit(waitStatus: waitStatus)
      finish(&state)
    }
    exited.fulfill()
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.outputGrace) { [self] in
      state.withLock { state in
        state.isDrained = true
        finish(&state)
      }
    }
  }

  private func finish(_ state: inout State) {
    guard let exit = state.exit, state.isDrained, !state.isFinished else { return }
    state.isFinished = true
    continuation.yield(.finished(exit))
    continuation.finish()
    finished.fulfill()
  }
}

extension winsize {
  fileprivate init(_ size: TerminalSize) {
    self.init(
      ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns), ws_xpixel: 0, ws_ypixel: 0)
  }
}
