import Dependencies
import Foundation
import SlipstreamCore

struct WorkspaceNameClient: Sendable {
  /// A nil name clears the user's name, so the agent's name shows again.
  var rename: @Sendable (_ sessionID: String, _ name: String?) async throws -> Void
  /// Stores the agent's name unless the session already has one; false when it did.
  var setAgentName: @Sendable (_ sessionID: String, _ name: String) async throws -> Bool
}

extension WorkspaceNameClient: DependencyKey {
  static var liveValue: Self {
    let store = DescriptorDiscovery.storeURL(
      environment: ProcessInfo.processInfo.environment,
      home: FileManager.default.homeDirectoryForCurrentUser
    )
    let transport = ControlTransport(store: store)
    return Self(
      rename: { try await transport.renameSession(sessionID: $0, name: $1) },
      setAgentName: { try await transport.nameSession(sessionID: $0, name: $1) }
    )
  }

  static var testValue: Self {
    Self(
      rename: unimplemented("WorkspaceNameClient.rename"),
      setAgentName: unimplemented("WorkspaceNameClient.setAgentName", placeholder: false)
    )
  }
}

extension DependencyValues {
  var workspaceName: WorkspaceNameClient {
    get { self[WorkspaceNameClient.self] }
    set { self[WorkspaceNameClient.self] = newValue }
  }
}
