import Dependencies
import Foundation
import SlipstreamCore

struct DaemonClient: Sendable {
  var storeID: String
  var discover: @Sendable () async throws -> DaemonDescriptor
  var sessions: @Sendable (DaemonDescriptor) async throws -> [SessionSummary]
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
      sessions: { try await transport.sessions($0) },
      sessionStart: { descriptor, sessionID in
        guard case .sessionStarted(let start) = try await transport.firstEvent(descriptor, sessionID: sessionID)?.payload
        else { return nil }
        return start
      },
      follow: { transport.follow($0, sessionID: $1, after: $2) },
      clips: { try await transport.clips($0, sessionID: $1, seq: $2) },
      interfaces: { try await transport.interfaces(
        $0, sessionID: $1, before: $2, after: $3,
        pathPrefix: $4, afterPath: $5, includeIdentical: $6) },
      blob: { try await transport.blob($0, sha256: $1) }
    )
  }

  static var testValue: DaemonClient {
    DaemonClient(
      storeID: "test-store",
      discover: unimplemented("DaemonClient.discover"),
      sessions: unimplemented("DaemonClient.sessions", placeholder: []),
      sessionStart: unimplemented("DaemonClient.sessionStart", placeholder: nil),
      follow: unimplemented("DaemonClient.follow", placeholder: AsyncThrowingStream { $0.finish() }),
      clips: unimplemented("DaemonClient.clips"),
      interfaces: unimplemented("DaemonClient.interfaces"),
      blob: unimplemented("DaemonClient.blob")
    )
  }
}

extension DependencyValues {
  var daemon: DaemonClient {
    get { self[DaemonClient.self] }
    set { self[DaemonClient.self] = newValue }
  }
}
