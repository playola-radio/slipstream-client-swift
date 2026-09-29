import Dependencies
import Foundation
import SlipstreamCore

struct FunctionFixtureCatalog: Sendable {
  let caseNames: [String]
  let comparison: InterfaceComparison
  let afterPath: String?
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
      let caseURL = cases.appending(path: name)
      let data = try Data(contentsOf: caseURL.appending(path: "expected.json"))
      let requestURL = caseURL.appending(path: "request.txt")
      let afterPath: String?
      if FileManager.default.fileExists(atPath: requestURL.path) {
        let request = try String(contentsOf: requestURL, encoding: .utf8)
        let target =
          request.split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init) ?? ""
        afterPath = URLComponents(string: target)?.queryItems?
          .first { $0.name == "after_path" }?.value
      } else {
        afterPath = nil
      }
      return FunctionFixtureCatalog(
        caseNames: names, comparison: try InterfaceComparison.decode(data), afterPath: afterPath)
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
