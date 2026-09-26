import CustomDump
import Foundation
import Testing
@testable import SlipstreamViewer

@Suite(.serialized)
struct SavedQuestionsClientTests {
  private static let key = "personalSavedQuestions"

  @Test func concurrentAddsFromTwoWindowsBothPersistInsteadOfOverwritingEachOther() async throws {
    UserDefaults.standard.removeObject(forKey: Self.key)
    defer { UserDefaults.standard.removeObject(forKey: Self.key) }

    let client = SavedQuestionsClient.liveValue
    async let first = client.add("From window A")
    async let second = client.add("From window B")
    _ = try await (first, second)

    let persisted = try await client.load()
    expectNoDifference(Set(persisted), ["From window A", "From window B"])
    #expect(persisted.count == 2)
  }
}
