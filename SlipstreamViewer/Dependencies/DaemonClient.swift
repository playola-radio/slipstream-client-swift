import Dependencies
import Foundation
import SlipstreamCore

struct DaemonClient: Sendable {
  var discover: @Sendable () async throws -> DaemonDescriptor
  var sessions: @Sendable (DaemonDescriptor) async throws -> [SessionSummary]
  var sessionRoot: @Sendable (DaemonDescriptor, String) async throws -> String?
  var follow: @Sendable (DaemonDescriptor, String, Seq) -> AsyncThrowingStream<StreamItem, any Error>
  var clips: @Sendable (DaemonDescriptor, String, Seq) async throws -> ClipsResponse
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
      discover: { try DescriptorDiscovery.discover(store: store) },
      sessions: { try await transport.sessions($0) },
      sessionRoot: { descriptor, sessionID in
        guard case .sessionStarted(let root) = try await transport.firstEvent(descriptor, sessionID: sessionID)?.payload
        else { return nil }
        return root
      },
      follow: { transport.follow($0, sessionID: $1, after: $2) },
      clips: { try await transport.clips($0, sessionID: $1, seq: $2) },
      blob: { try await transport.blob($0, sha256: $1) }
    )
  }

  static var testValue: DaemonClient {
    DaemonClient(
      discover: unimplemented("DaemonClient.discover"),
      sessions: unimplemented("DaemonClient.sessions", placeholder: []),
      sessionRoot: unimplemented("DaemonClient.sessionRoot", placeholder: nil),
      follow: unimplemented("DaemonClient.follow", placeholder: AsyncThrowingStream { $0.finish() }),
      clips: unimplemented("DaemonClient.clips"),
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
