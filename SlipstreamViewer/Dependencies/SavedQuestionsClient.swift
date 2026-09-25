import Dependencies
import Foundation

struct SavedQuestionsClient: Sendable {
  var load: @Sendable () async throws -> [String]
  var save: @Sendable ([String]) async throws -> Void
}

extension SavedQuestionsClient: DependencyKey {
  static var liveValue: Self {
    Self(
      load: {
        guard let data = UserDefaults.standard.data(forKey: "personalSavedQuestions") else { return [] }
        return try JSONDecoder().decode([String].self, from: data)
      },
      save: { questions in
        let data = try JSONEncoder().encode(questions)
        UserDefaults.standard.set(data, forKey: "personalSavedQuestions")
        guard UserDefaults.standard.data(forKey: "personalSavedQuestions") == data else {
          throw CocoaError(.fileWriteUnknown)
        }
      }
    )
  }

  static var testValue: Self {
    Self(load: unimplemented("SavedQuestionsClient.load"), save: unimplemented("SavedQuestionsClient.save"))
  }
}

extension DependencyValues {
  var savedQuestions: SavedQuestionsClient {
    get { self[SavedQuestionsClient.self] }
    set { self[SavedQuestionsClient.self] = newValue }
  }
}
