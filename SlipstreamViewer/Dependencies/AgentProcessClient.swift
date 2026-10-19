import Darwin
import Dependencies
import Foundation
import SlipstreamCore
import Synchronization

struct AgentLaunch: Equatable, Sendable {
  var executable: String
  var arguments: [String]
  var environment: [String: String]
  var directory: String
}

enum AgentProcessEvent: Equatable, Sendable {
  case line(Data)
  case overflow
  /// `status` is the exit code, or 128 + the signal number if a signal ended the process.
  case exited(status: Int32, stderrTail: String)
}

enum AgentProcessError: Error, Equatable {
  case launchFailed(errno: Int32)
  case writeFailed(errno: Int32)
}

struct AgentProcessHandle: Sendable {
  var events: AsyncStream<AgentProcessEvent>
  var write: @Sendable (Data) async throws -> Void
  var shutdown: @Sendable () async -> Void
}

struct AgentProcessClient: Sendable {
  var launch: @Sendable (AgentLaunch) async throws -> AgentProcessHandle
}

extension AgentProcessClient: DependencyKey {
  static var liveValue: Self {
    Self(launch: { launch in
      let process = try AgentProcess(launch)
      return AgentProcessHandle(
        events: process.events,
        write: { try await process.input.write($0) },
        shutdown: { await process.shutdown() }
      )
    })
  }

  static var testValue: Self {
    Self(launch: unimplemented("AgentProcessClient.launch"))
  }
}

extension DependencyValues {
  var agentProcess: AgentProcessClient {
    get { self[AgentProcessClient.self] }
    set { self[AgentProcessClient.self] = newValue }
  }
}

/// A child process in its own process group, so shutdown reaches everything it started.
///
/// `.exited` is the last event. It is sent once the process has exited and both output pipes
/// have closed, or `outputGrace` after the exit if something the process left behind still holds
/// a pipe open.
///
/// The exited process stays a zombie until `shutdown` reaps it, so its pid, and with it the
/// process group id, can't be reused by an unrelated process while shutdown is signalling.
private final class AgentProcess: Sendable {
  static let terminationGrace = 3.0
  static let outputGrace = 1.0
  static let stderrTailBytes = 4096

  let events: AsyncStream<AgentProcessEvent>
  let input: AgentProcessInput
  private let pid: pid_t
  private let continuation: AsyncStream<AgentProcessEvent>.Continuation
  private let stdout: FileHandle
  private let stderr: FileHandle
  private let output = Mutex(Output())
  private let exited = OneShot()
  private let finished = OneShot()
  private let isShuttingDown = Mutex(false)

  private struct Output {
    var framer = JSONLineFramer()
    var stderrTail = Data()
    var openPipes = 2
    var status: Int32?
    var isFinished = false
  }

  init(_ launch: AgentLaunch) throws {
    let pipes = try Self.makePipes(3)
    let (stdinPipe, stdoutPipe, stderrPipe) = (pipes[0], pipes[1], pipes[2])
    let parentEnds = [stdinPipe.write, stdoutPipe.read, stderrPipe.read]
    let childEnds = [stdinPipe.read, stdoutPipe.write, stderrPipe.write]
    defer { childEnds.forEach { close($0) } }

    do {
      pid = try Self.spawn(launch, stdin: stdinPipe.read, stdout: stdoutPipe.write, stderr: stderrPipe.write)
    } catch {
      parentEnds.forEach { close($0) }
      throw error
    }

    _ = fcntl(stdinPipe.write, F_SETNOSIGPIPE, 1)
    input = AgentProcessInput(descriptor: stdinPipe.write)
    stdout = FileHandle(fileDescriptor: stdoutPipe.read, closeOnDealloc: true)
    stderr = FileHandle(fileDescriptor: stderrPipe.read, closeOnDealloc: true)
    (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)

    stdout.readabilityHandler = { [self] handle in
      let chunk = handle.availableData
      if chunk.isEmpty { pipeClosed(handle) } else { stdoutReceived(chunk) }
    }
    stderr.readabilityHandler = { [self] handle in
      let chunk = handle.availableData
      if chunk.isEmpty { pipeClosed(handle) } else { stderrReceived(chunk) }
    }
    Thread.detachNewThread { [self] in waitForExit() }
  }

  /// Closes stdin and sends SIGTERM to the process group, then SIGKILL after
  /// `terminationGrace` (always, to catch children that outlived the leader), and reaps the
  /// process. Returns once `.exited` has been sent. Call it when done with the handle, even after
  /// `.exited`. Safe to call more than once.
  func shutdown() async {
    let isFirst = isShuttingDown.withLock { started in
      defer { started = true }
      return !started
    }
    if isFirst {
      // Not awaited: a write blocked on a full pipe would hold the closing back until the
      // process dies.
      Task { await input.close() }
      kill(-pid, SIGTERM)
      await exited.wait(timeout: Self.terminationGrace)
      kill(-pid, SIGKILL)
      await exited.wait()
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
    await finished.wait()
  }

  private func stdoutReceived(_ chunk: Data) {
    output.withLock { output in
      guard !output.isFinished else { return }
      for framed in output.framer.append(chunk) {
        switch framed {
        case .line(let line): continuation.yield(.line(line))
        case .overflow: continuation.yield(.overflow)
        }
      }
    }
  }

  private func stderrReceived(_ chunk: Data) {
    output.withLock { output in
      output.stderrTail.append(chunk)
      if output.stderrTail.count > Self.stderrTailBytes {
        output.stderrTail = Data(output.stderrTail.suffix(Self.stderrTailBytes))
      }
    }
  }

  private func pipeClosed(_ handle: FileHandle) {
    handle.readabilityHandler = nil
    try? handle.close()
    output.withLock { output in
      output.openPipes -= 1
      if output.openPipes == 0 { finish(&output) }
    }
  }

  /// Waits without reaping (`WNOWAIT`); `shutdown` reaps.
  private func waitForExit() {
    var info = siginfo_t()
    while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
    let exitStatus = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
    output.withLock { output in
      output.status = exitStatus
      if output.openPipes == 0 { finish(&output) }
    }
    exited.fulfill()
    // The handlers stay installed so the pipes still close once whatever holds them dies.
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.outputGrace) { [self] in
      output.withLock { finish(&$0) }
    }
  }

  private func finish(_ output: inout Output) {
    guard let status = output.status, !output.isFinished else { return }
    output.isFinished = true
    continuation.yield(.exited(status: status, stderrTail: Self.decodeTail(output.stderrTail)))
    continuation.finish()
    finished.fulfill()
  }

  /// Drops UTF-8 continuation bytes left at the front by the ring cut.
  private static func decodeTail(_ tail: Data) -> String {
    String(decoding: tail.drop(while: { $0 & 0xC0 == 0x80 }), as: UTF8.self)
  }

  private static func makePipes(_ count: Int) throws -> [(read: Int32, write: Int32)] {
    var pipes: [(read: Int32, write: Int32)] = []
    for _ in 0..<count {
      var descriptors: [Int32] = [0, 0]
      guard pipe(&descriptors) == 0 else {
        let code = errno
        pipes.forEach { close($0.read); close($0.write) }
        throw AgentProcessError.launchFailed(errno: code)
      }
      for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
      pipes.append((descriptors[0], descriptors[1]))
    }
    return pipes
  }

  private static func spawn(
    _ launch: AgentLaunch, stdin: Int32, stdout: Int32, stderr: Int32
  ) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    try check(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try check(posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO))
    try check(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO))
    try check(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO))
    try check(posix_spawn_file_actions_addchdir_np(&actions, launch.directory))

    var attributes: posix_spawnattr_t?
    try check(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try check(
      posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
      )
    )
    try check(posix_spawnattr_setpgroup(&attributes, 0))
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    try check(posix_spawnattr_setsigdefault(&attributes, &allSignals))
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    try check(posix_spawnattr_setsigmask(&attributes, &noSignals))

    let argv = ([launch.executable] + launch.arguments).map { strdup($0) } + [nil]
    let envp = launch.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }

    var pid: pid_t = 0
    try check(posix_spawn(&pid, launch.executable, &actions, &attributes, argv, envp))
    return pid
  }

  /// The `posix_spawn` family returns an error number instead of setting `errno`.
  private static func check(_ result: Int32) throws {
    guard result == 0 else { throw AgentProcessError.launchFailed(errno: result) }
  }
}

/// Serialises writes to the child's stdin. Runs on its own queue so a write blocked on a full
/// pipe doesn't hold a cooperative thread.
private actor AgentProcessInput {
  private let queue = DispatchSerialQueue(label: "AgentProcessInput")
  private var descriptor: Int32?

  nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    if let descriptor { Darwin.close(descriptor) }
  }

  func write(_ data: Data) throws {
    guard let descriptor else { throw AgentProcessError.writeFailed(errno: EPIPE) }
    var failure: Int32?
    data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if count >= 0 {
          offset += count
        } else if errno != EINTR {
          failure = errno
          return
        }
      }
    }
    if let failure {
      close()
      throw AgentProcessError.writeFailed(errno: failure)
    }
  }

  func close() {
    guard let descriptor else { return }
    Darwin.close(descriptor)
    self.descriptor = nil
  }
}

/// Fires once; any number of callers can wait for it.
private final class OneShot: Sendable {
  private struct State {
    var hasFired = false
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  }

  private let state = Mutex(State())

  func fulfill() {
    let waiters = state.withLock { state in
      state.hasFired = true
      defer { state.waiters = [:] }
      return state.waiters.values
    }
    waiters.forEach { $0.resume() }
  }

  /// Also returns if `timeout` seconds pass first.
  func wait(timeout: TimeInterval? = nil) async {
    let id = UUID()
    await withCheckedContinuation { continuation in
      let hasFired = state.withLock { state in
        if !state.hasFired { state.waiters[id] = continuation }
        return state.hasFired
      }
      if hasFired {
        continuation.resume()
      } else if let timeout {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
          state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
      }
    }
  }
}
