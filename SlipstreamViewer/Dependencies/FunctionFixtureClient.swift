import Dependencies
import Foundation
import SlipstreamCore

struct FunctionFixtureCatalog: Sendable {
  let caseNames: [String]
  let comparison: InterfaceComparison
}

enum FunctionFixtureError: Error {
  case unknownCase(String, available: [String])
}

struct FunctionFixtureClient: Sendable {
  var load: @Sendable (URL, String) throws -> FunctionFixtureCatalog
}

extension FunctionFixtureClient: DependencyKey {
  static var liveValue: Self {
    Self { root, name in
      let cases = root.appending(path: "cases")
      let names = try FileManager.default.contentsOfDirectory(
        at: cases, includingPropertiesForKeys: nil
      )
      .filter { FileManager.default.fileExists(atPath: $0.appending(path: "expected.json").path) }
      .map(\.lastPathComponent)
      .sorted()
      guard names.contains(name) else {
        throw FunctionFixtureError.unknownCase(name, available: names)
      }
      let data = try Data(contentsOf: cases.appending(path: name).appending(path: "expected.json"))
      return FunctionFixtureCatalog(
        caseNames: names, comparison: try InterfaceComparison.decode(data))
    }
  }

  static var testValue: Self {
    Self(load: unimplemented("FunctionFixtureClient.load"))
  }
}

extension DependencyValues {
  var functionFixtures: FunctionFixtureClient {
    get { self[FunctionFixtureClient.self] }
    set { self[FunctionFixtureClient.self] = newValue }
  }
}
