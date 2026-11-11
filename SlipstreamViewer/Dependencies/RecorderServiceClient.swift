import AppKit
import Darwin
import Dependencies
import Foundation
import SlipstreamCore

struct ShimRun: Equatable, Sendable {
  var command: String
  var exitCode: Int32
  var output: String
}

struct RecorderServiceClient: Sendable {
  var job: @Sendable () async throws -> LaunchdJob?
  var terminate: @Sendable (Int32) throws -> Void
  var ownerLockPID: @Sendable (URL) -> Int32?
  var daemonBuild: @Sendable (URL) async throws -> DaemonBuild?
  var processDescription: @Sendable (Int32) async -> String?
  var logSize: @Sendable () -> UInt64
  var logSince: @Sendable (UInt64) throws -> String
  var runShim: @Sendable ([String]) async throws -> ShimRun
  var openLog: @Sendable () -> Void
}

struct RecorderServiceError: Error, Equatable, CustomStringConvertible {
  var description: String
}

extension RecorderServiceClient {
  static let label = "radio.playola.slipstream"
  static let logFile = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Logs/slipstream/daemon.log")

  private static func commandLine(_ words: [String]) -> String {
    words.map { word in
      word.allSatisfy { $0.isLetter || $0.isNumber || "/-_.=:@%+,".contains($0) }
        ? word : "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
    .joined(separator: " ")
  }
}

extension RecorderServiceClient: DependencyKey {
  static var liveValue: Self {
    Self(
      job: {
        let (output, status) = try await WorkspaceClient.runInBackground(
          "/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], environment: ProcessInfo.processInfo.environment)
        if status == 0 { return LaunchctlPrint.job(in: output) }
        if output.contains("Could not find service") { return nil }
        throw RecorderServiceError(
          description: "$ launchctl print gui/\(getuid())/\(label)\nexit \(status)\n\(output)")
      },
      terminate: { pid in
        guard kill(pid, SIGTERM) == 0 else {
          let code = errno
          throw RecorderServiceError(description: "kill -TERM \(pid): \(String(cString: strerror(code))) (errno \(code))")
        }
      },
      ownerLockPID: { store in
        (try? String(contentsOf: store.appending(path: "owner.lock"), encoding: .utf8)).flatMap(OwnerLock.pid(in:))
      },
      daemonBuild: { store in
        do {
          return try await ControlTransport(store: store).status()
        } catch QuestionError.unavailable {
          return nil
        }
      },
      processDescription: { pid in
        guard
          let (output, status) = try? await WorkspaceClient.runInBackground(
            "/bin/ps", ["-o", "lstart=,command=", "-p", "\(pid)"], environment: ProcessInfo.processInfo.environment),
          status == 0
        else { return nil }
        return output.trimmingCharacters(in: .newlines)
      },
      logSize: {
        let attributes = try? FileManager.default.attributesOfItem(atPath: logFile.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
      },
      logSince: { offset in
        let handle = try FileHandle(forReadingFrom: logFile)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // A rotated log is shorter than the recorded size, so all of it is new.
        try handle.seek(toOffset: offset <= end ? offset : 0)
        return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
      },
      runShim: { arguments in
        let environment = (try? await AgentEnvironmentClient.loginEnvironment()) ?? ProcessInfo.processInfo.environment
        try Task.checkCancellation()
        let shim = RuntimeInstallClient.shim.path
        let (output, status) = try await WorkspaceClient.runInBackground(
          shim, arguments, environment: environment, keepsAllOutput: true)
        return ShimRun(command: commandLine([shim] + arguments), exitCode: status, output: output)
      },
      openLog: { _ = NSWorkspace.shared.open(logFile) }
    )
  }

  static var testValue: Self {
    Self(
      job: unimplemented("RecorderServiceClient.job", placeholder: nil),
      terminate: unimplemented("RecorderServiceClient.terminate"),
      ownerLockPID: unimplemented("RecorderServiceClient.ownerLockPID", placeholder: nil),
      daemonBuild: unimplemented("RecorderServiceClient.daemonBuild", placeholder: nil),
      processDescription: unimplemented("RecorderServiceClient.processDescription", placeholder: nil),
      logSize: unimplemented("RecorderServiceClient.logSize", placeholder: 0),
      logSince: unimplemented("RecorderServiceClient.logSince", placeholder: ""),
      runShim: unimplemented("RecorderServiceClient.runShim"),
      openLog: unimplemented("RecorderServiceClient.openLog")
    )
  }
}

extension DependencyValues {
  var recorderService: RecorderServiceClient {
    get { self[RecorderServiceClient.self] }
    set { self[RecorderServiceClient.self] = newValue }
  }
}
