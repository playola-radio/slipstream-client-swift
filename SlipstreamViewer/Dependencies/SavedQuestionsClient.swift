import Dependencies
import Foundation

struct SavedQuestionsClient: Sendable {
  var load: @Sendable () async throws -> [String]
  var add: @Sendable (String) async throws -> [String]
}

actor SavedQuestionsStore {
  static let shared = SavedQuestionsStore(userDefaults: .standard)

  private static let key = "personalSavedQuestions"

  private let userDefaults: UserDefaults

  init(userDefaults: UserDefaults) {
    self.userDefaults = userDefaults
  }

  func load() throws -> [String] {
    guard let data = userDefaults.data(forKey: Self.key) else { return [] }
    return try JSONDecoder().decode([String].self, from: data)
  }

  func add(_ text: String) throws -> [String] {
    var questions = try load()
    if !questions.contains(text) { questions.append(text) }
    let data = try JSONEncoder().encode(questions)
    userDefaults.set(data, forKey: Self.key)
    return questions
  }
}

extension SavedQuestionsClient: DependencyKey {
  static var liveValue: Self {
    Self(
      load: { try await SavedQuestionsStore.shared.load() },
      add: { text in try await SavedQuestionsStore.shared.add(text) }
    )
  }

  static var testValue: Self {
    Self(load: unimplemented("SavedQuestionsClient.load"), add: unimplemented("SavedQuestionsClient.add"))
  }
}

extension DependencyValues {
  var savedQuestions: SavedQuestionsClient {
    get { self[SavedQuestionsClient.self] }
    set { self[SavedQuestionsClient.self] = newValue }
  }
}
