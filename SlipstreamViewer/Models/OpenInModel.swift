import AppKit
import Dependencies
import IdentifiedCollections
import Sharing

/// The toolbar's Open button: opens the selected workspace folder in the last app picked.
@MainActor
@Observable
final class OpenInModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.openIn) var openIn

  // MARK: - Shared State

  @ObservationIgnored @Shared(.openInAppID) var selectedAppID

  // MARK: - Properties

  private(set) var apps: IdentifiedArrayOf<OpenInApp> = []
  var folder: String?
  var isFailurePresented = false
  private(set) var failureText = ""

  // MARK: - Display Text

  let failureTitle = "Couldn't open the workspace"
  let failureDismissText = "OK"

  var openHelpText: String { selectedApp.map { "Open in \($0.name)" } ?? "Open" }

  // MARK: - View Helpers

  var selectedApp: OpenInApp? { selectedAppID.flatMap { apps[id: $0] } ?? apps.first }
  var isOpenDisabled: Bool { folder == nil || selectedApp == nil }

  func icon(for app: OpenInApp) -> NSImage { openIn.icon(app) }

  // MARK: - User Actions

  func viewAppeared() {
    apps = IdentifiedArray(uniqueElements: openIn.installedApps())
  }

  func openTapped() async {
    guard let selectedApp else { return }
    await open(in: selectedApp)
  }

  func appSelected(_ id: OpenInApp.ID) async {
    guard let app = apps[id: id] else { return }
    $selectedAppID.withLock { $0 = id }
    await open(in: app)
  }

  // MARK: - Private Helpers

  private func open(in app: OpenInApp) async {
    guard let folder else { return }
    do {
      try await openIn.open(URL(filePath: folder), app)
    } catch {
      failureText = "\(app.name) couldn't open \(folder): \(error.localizedDescription)"
      isFailurePresented = true
    }
  }
}

extension SharedKey where Self == AppStorageKey<String?>.Default {
  static var openInAppID: Self {
    Self[.appStorage("openInAppID"), default: nil]
  }
}
