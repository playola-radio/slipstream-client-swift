import Darwin
import Foundation
import SlipstreamCore
import SwiftTerm
import Synchronization

/// A shell or command in a pseudo-terminal, leading its own session, so its pid is also its
/// process group id.
///
/// `.finished` is the last event. It is sent once the process has exited and the terminal's
/// output has been read to the end, or `outputGrace` after the exit, closing the terminal, if
/// something the process left behind still holds it open.
///
/// Reading pauses while more than `bufferLimit` bytes wait in `events`, so a program printing
/// faster than its output is consumed blocks instead of filling memory.
///
/// The process is reaped as soon as it exits. Reaping and signalling share a lock, so its pid,
/// and with it the process group id, is never signalled once an unrelated process could reuse it.
final class TerminalProcess: Sendable {
  static let hangupGrace = 2.0
  static let outputGrace = 1.0
  static let bufferLimit = 1 << 20
  private static let forkLock = Mutex(())

  let events: AsyncStream<TerminalEvent>
  private let pid: pid_t
  private let continuation: AsyncStream<TerminalEvent>.Continuation
  /// nil once closed. Writes, resizes and busy checks hold the lock, so they never touch a
  /// descriptor number the system has since handed out again.
  private let master: Mutex<Int32?>
  private let reader: OutputReader
  private let writer = DispatchQueue(label: "TerminalProcess.write")
  private let state = Mutex(State())
  private let exited = OneShot()
  private let finished = OneShot()
  private let isStopping = Mutex(false)
  private let isReaped = Mutex(false)

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
    // SwiftTerm's child ignores a failed chdir and would start the shell in the app's folder.
    guard access(launch.directory, X_OK) == 0 else {
      throw TerminalLaunchError(text: "Couldn't open the folder \(launch.directory)")
    }

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
    let (buffered, continuation) = AsyncStream.makeStream(of: TerminalEvent.self, bufferingPolicy: .unbounded)
    let iterator = EventIterator(buffered.makeAsyncIterator())
    let reader = OutputReader(descriptor: child.masterFd)
    self.continuation = continuation
    self.reader = reader
    events = AsyncStream {
      let event = await iterator.next()
      if case .output(let bytes) = event { reader.consumed(bytes.count) }
      return event
    }

    reader.source.setEventHandler { [self] in readAvailable(from: child.masterFd) }
    // Dispatch runs this after the last read, and the descriptor stays open until then.
    reader.source.setCancelHandler { [self] in
      master.withLock { descriptor in
        if let descriptor { close(descriptor) }
        descriptor = nil
      }
      state.withLock { state in
        state.isDrained = true
        finish(&state)
      }
    }
    reader.source.activate()
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

  /// Hangs up the foreground program and the shell and kills both after `hangupGrace`. Returns
  /// once `.finished` has been sent. Safe to call more than once.
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
    }
    await finished.wait()
  }

  private func signalGroups(_ signal: Int32) {
    // The terminal only reports a group that still has members, so this holds even once the shell
    // has been reaped.
    let foreground = master.withLock { descriptor in descriptor.map(tcgetpgrp) ?? -1 }
    if foreground > 0 && foreground != pid { kill(-foreground, signal) }
    isReaped.withLock { isReaped in
      guard !isReaped else { return }
      // Before the child's setsid there is no group yet; the unreaped pid is still ours.
      if kill(-pid, signal) != 0 { kill(pid, signal) }
    }
  }

  /// Returns the number of bytes read; 0 when nothing was waiting or the output has ended.
  @discardableResult
  private func readAvailable(from descriptor: Int32) -> Int {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let count = read(descriptor, &buffer, buffer.count)
    guard count > 0 else {
      if count == 0 || (errno != EAGAIN && errno != EINTR) {
        // End of output: every holder of the terminal has closed it (EIO on macOS).
        reader.cancel()
      }
      return 0
    }
    let bytes = Array(buffer[..<count])
    state.withLock { state in
      guard !state.isFinished else { return }
      reader.sent(count)
      continuation.yield(.output(bytes))
    }
    return count
  }

  /// Waits for the exit without reaping (`WNOWAIT`), so the wait doesn't hold the signalling
  /// lock, then reaps under it.
  private func waitForExit() {
    var info = siginfo_t()
    while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
    var waitStatus: Int32 = 0
    isReaped.withLock { isReaped in
      while waitpid(pid, &waitStatus, 0) == -1 && errno == EINTR {}
      isReaped = true
    }
    state.withLock { state in
      state.exit = TerminalExit(waitStatus: waitStatus)
      finish(&state)
    }
    exited.fulfill()
    reader.queue.asyncAfter(deadline: .now() + Self.outputGrace) { [self] in
      // On the read queue, so the descriptor stays open while this reads what is waiting.
      if let descriptor = master.withLock({ $0 }) {
        var total = 0
        while total < Self.bufferLimit {
          let count = readAvailable(from: descriptor)
          guard count > 0 else { break }
          total += count
        }
      }
      // Give up on the rest; the cancel handler closes the terminal and finishes.
      reader.cancel()
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

/// The terminal's read source. It is suspended while more than `bufferLimit` bytes of output
/// wait for the consumer and resumed once half of them have been consumed.
private final class OutputReader: Sendable {
  let queue = DispatchQueue(label: "TerminalProcess.read")
  let source: any DispatchSourceRead
  private let flow = Mutex(Flow())

  private struct Flow {
    var bufferedBytes = 0
    var isSuspended = false
    var isCancelled = false
  }

  init(descriptor: Int32) {
    source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
  }

  func sent(_ count: Int) {
    flow.withLock { flow in
      flow.bufferedBytes += count
      guard flow.bufferedBytes > TerminalProcess.bufferLimit, !flow.isSuspended, !flow.isCancelled else { return }
      flow.isSuspended = true
      source.suspend()
    }
  }

  func consumed(_ count: Int) {
    flow.withLock { flow in
      flow.bufferedBytes -= count
      guard flow.isSuspended, flow.bufferedBytes <= TerminalProcess.bufferLimit / 2 else { return }
      flow.isSuspended = false
      source.resume()
    }
  }

  /// A suspended source never runs its cancel handler, so this resumes it too.
  func cancel() {
    flow.withLock { flow in
      flow.isCancelled = true
      source.cancel()
      guard flow.isSuspended else { return }
      flow.isSuspended = false
      source.resume()
    }
  }
}

/// `events` has a single consumer, so this is never used from two tasks at once.
private final class EventIterator: @unchecked Sendable {
  private var base: AsyncStream<TerminalEvent>.Iterator

  init(_ base: AsyncStream<TerminalEvent>.Iterator) {
    self.base = base
  }

  func next() async -> TerminalEvent? {
    await base.next()
  }
}

extension winsize {
  fileprivate init(_ size: TerminalSize) {
    self.init(
      ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns), ws_xpixel: 0, ws_ypixel: 0)
  }
}
