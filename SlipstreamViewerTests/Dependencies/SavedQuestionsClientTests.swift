import CustomDump
import Foundation
import Testing
@testable import SlipstreamViewer

@Suite(.serialized)
struct SavedQuestionsClientTests {
  @Test func manyConcurrentAddsFromDistinctWindowsAllPersist() async throws {
    let suiteName = "SavedQuestionsClientTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let store = SavedQuestionsStore(userDefaults: UserDefaults(suiteName: suiteName)!)
    let client = SavedQuestionsClient(
      load: { try await store.load() },
      add: { text in try await store.add(text) }
    )

    let questionCount = 20
    let questions = (0..<questionCount).map { "Question \($0)" }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for question in questions {
        group.addTask { _ = try await client.add(question) }
      }
      try await group.waitForAll()
    }

    let persisted = try await client.load()
    expectNoDifference(Set(persisted), Set(questions))
    #expect(persisted.count == questionCount)
  }
}
