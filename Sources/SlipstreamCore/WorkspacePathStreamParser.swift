import Foundation

public struct WorkspacePathStreamParser: Sendable {
  public static let prefix = "workspace_path: "

  private static let cr: UInt8 = 0x0D
  private static let lf: UInt8 = 0x0A
  private static let maxLineBytes = 4_096

  private var buffer: [UInt8] = []
  private var isDiscarding = false

  public init() {}

  public mutating func consume(_ bytes: some Collection<UInt8>) -> [String] {
    var paths: [String] = []
    for byte in bytes {
      if byte == Self.lf {
        if !isDiscarding, let path = finishedPath() {
          paths.append(path)
        }
        buffer.removeAll(keepingCapacity: true)
        isDiscarding = false
      } else if !isDiscarding {
        buffer.append(byte)
        if buffer.count > Self.maxLineBytes {
          buffer.removeAll(keepingCapacity: true)
          isDiscarding = true
        }
      }
    }
    return paths
  }

  private func finishedPath() -> String? {
    var line = buffer[...]
    if line.last == Self.cr {
      line = line.dropLast()
    }
    guard let text = String(bytes: line, encoding: .utf8), text.hasPrefix(Self.prefix) else {
      return nil
    }
    return String(text.dropFirst(Self.prefix.count))
  }
}

public enum ManagedWorkspacePath {
  public static func contains(_ folder: String, root: String) -> Bool {
    let rootComponents = URL(filePath: root).pathComponents
    let folderComponents = URL(filePath: folder).pathComponents
    return folderComponents.count == rootComponents.count + 2
      && folderComponents.starts(with: rootComponents)
  }
}
