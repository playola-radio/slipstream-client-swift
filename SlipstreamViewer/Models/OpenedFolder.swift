import Foundation
import Sharing

/// A folder the user recorded in the app. Keyed by folder, not session: recreating a folder starts a
/// new session, and the user opened the folder.
struct OpenedFolder: Codable, Hashable, Sendable {
  let storeID: String
  /// As `ChangeStreamPageModel.normalizedFolder` returns it.
  let folder: String
}

extension SharedKey where Self == FileStorageKey<Set<OpenedFolder>>.Default {
  static var openedFolders: Self {
    Self[
      .fileStorage(
        .applicationSupportDirectory
          .appending(component: Bundle.main.bundleIdentifier ?? "com.playola.SlipstreamViewer")
          .appending(component: "openedFolders.json")),
      default: []
    ]
  }
}
