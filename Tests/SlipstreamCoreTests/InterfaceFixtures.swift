import Foundation

enum InterfaceFixtures {
  static let directory = Bundle.module.resourceURL!.appending(path: "Fixtures/interface-v2")

  static func contents(of relativePath: String) throws -> Data {
    try Data(contentsOf: directory.appending(path: relativePath))
  }

  static func caseNames() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "cases").path).sorted()
  }

  static func successCaseNames() throws -> [String] {
    try caseNames().filter { FileManager.default.fileExists(atPath: directory.appending(path: "cases/\($0)/expected.json").path) }
  }

  static func expected(_ caseName: String) throws -> Data {
    try contents(of: "cases/\(caseName)/expected.json")
  }

  static func allFiles() throws -> [String: Data] {
    let root = directory.standardizedFileURL.path + "/"
    var files: [String: Data] = [:]
    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
      files[String(url.standardizedFileURL.path.dropFirst(root.count))] = try Data(contentsOf: url)
    }
    return files
  }
}
