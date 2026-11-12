import Dependencies
import Foundation
import SlipstreamCore

struct DaemonClient: Sendable {
  var storeID: String
  var discover: @Sendable () async throws -> DaemonDescriptor
  var sessions: @Sendable (DaemonDescriptor) async throws -> [SessionSummary]
  var listCaptures: @Sendable (DaemonDescriptor) async throws -> CaptureList?
  var sessionStart: @Sendable (DaemonDescriptor, String) async throws -> SessionStarted?
  var follow: @Sendable (DaemonDescriptor, String, Seq) -> AsyncThrowingStream<StreamItem, any Error>
  var clips: @Sendable (DaemonDescriptor, String, Seq) async throws -> ClipsResponse
  var interfaces: @Sendable (DaemonDescriptor, String, Seq, Seq, String?, String?, Bool) async throws -> InterfaceComparison
  var blob: @Sendable (DaemonDescriptor, String) async throws -> Data
}

extension DaemonClient: DependencyKey {
  static var liveValue: DaemonClient {
    let transport = DaemonTransport()
    let store = DescriptorDiscovery.storeURL(
      environment: ProcessInfo.processInfo.environment,
      home: FileManager.default.homeDirectoryForCurrentUser
    )
    return DaemonClient(
      storeID: store.standardizedFileURL.path,
      discover: { try DescriptorDiscovery.discover(store: store) },
      sessions: { descriptor in
        try await logged("sessions") { try await transport.sessions(descriptor) }
      },
      listCaptures: { descriptor in
        try await logged("listCaptures") { try await transport.captures(descriptor) }
      },
      sessionStart: { descriptor, sessionID in
        try await logged("sessionStart \(sessionID)") {
          guard case .sessionStarted(let start) = try await transport.firstEvent(descriptor, sessionID: sessionID)?.payload
          else { return nil }
          return start
        }
      },
      follow: { transport.follow($0, sessionID: $1, after: $2) },
      clips: { descriptor, sessionID, seq in
        try await logged("clips \(sessionID)") { try await transport.clips(descriptor, sessionID: sessionID, seq: seq) }
      },
      interfaces: { descriptor, sessionID, before, after, pathPrefix, afterPath, includeIdentical in
        try await logged("interfaces \(sessionID)") {
          try await transport.interfaces(
            descriptor, sessionID: sessionID, before: before, after: after,
            pathPrefix: pathPrefix, afterPath: afterPath, includeIdentical: includeIdentical)
        }
      },
      blob: { descriptor, sha256 in
        try await logged("blob \(sha256)") { try await transport.blob(descriptor, sha256: sha256) }
      }
    )
  }

  static var testValue: DaemonClient {
    DaemonClient(
      storeID: "test-store",
      discover: unimplemented("DaemonClient.discover"),
      sessions: unimplemented("DaemonClient.sessions", placeholder: []),
      listCaptures: unimplemented("DaemonClient.listCaptures", placeholder: nil),
      sessionStart: unimplemented("DaemonClient.sessionStart", placeholder: nil),
      follow: unimplemented("DaemonClient.follow", placeholder: AsyncThrowingStream { $0.finish() }),
      clips: unimplemented("DaemonClient.clips"),
      interfaces: unimplemented("DaemonClient.interfaces"),
      blob: unimplemented("DaemonClient.blob")
    )
  }
}

private func logged<T: Sendable>(_ operation: String, _ body: () async throws -> T) async throws -> T {
  do {
    return try await body()
  } catch {
    if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
      @Dependency(\.appLog) var appLog
      appLog.error("daemon", "\(operation) failed: \(error)")
    }
    throw error
  }
}

extension DependencyValues {
  var daemon: DaemonClient {
    get { self[DaemonClient.self] }
    set { self[DaemonClient.self] = newValue }
  }
}
