import Dependencies
import Foundation
import SlipstreamCore

struct QuestionClient: Sendable {
  var send: @Sendable (QuestionRequest) async throws -> QuestionAcknowledgment
}

extension QuestionClient: DependencyKey {
  static var liveValue: Self {
    let store = DescriptorDiscovery.storeURL(
      environment: ProcessInfo.processInfo.environment,
      home: FileManager.default.homeDirectoryForCurrentUser
    )
    let transport = ControlTransport(store: store)
    return Self(send: { try await transport.ask($0) })
  }

  static var testValue: Self { Self(send: unimplemented("QuestionClient.send")) }
}

extension DependencyValues {
  var questionClient: QuestionClient {
    get { self[QuestionClient.self] }
    set { self[QuestionClient.self] = newValue }
  }
}
