import Dependencies
import Foundation

struct SavedQuestionsClient: Sendable {
  var load: @Sendable () async throws -> [String]
  var add: @Sendable (String) async throws -> [String]
}

extension SavedQuestionsClient: DependencyKey {
  static var liveValue: Self {
    let load: @Sendable () throws -> [String] = {
      guard let data = UserDefaults.standard.data(forKey: "personalSavedQuestions") else { return [] }
      return try JSONDecoder().decode([String].self, from: data)
    }
    return Self(
      load: { try load() },
      add: { text in
        var questions = try load()
        if !questions.contains(text) { questions.append(text) }
        let data = try JSONEncoder().encode(questions)
        UserDefaults.standard.set(data, forKey: "personalSavedQuestions")
        return questions
      }
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
