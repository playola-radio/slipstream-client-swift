import Dependencies
import Foundation
import Observation

@MainActor
@Observable
final class FunctionChangesFixtureModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.functionFixtures) var fixtures

  // MARK: - Initialization

  init(root: URL?, initialCase: String) {
    self.root = root
    selectedCase = initialCase
    super.init()
  }

  // MARK: - Properties

  @ObservationIgnored private let root: URL?
  private(set) var caseNames: [String] = []
  var selectedCase: String
  private(set) var page: FunctionChangesPageModel?
  private(set) var errorText: String?

  // MARK: - Display Text

  let pickerTitle = "Pinned fixture"
  let loadingText = "Loading fixture…"

  // MARK: - User Actions

  func viewAppeared() { load(selectedCase) }
  func caseSelected(_ name: String) { load(name) }

  // MARK: - Private Helpers

  private func load(_ name: String) {
    guard let root else {
      errorText = "Set SLIPSTREAM_INTERFACE_FIXTURE_ROOT to the pinned interface-v2 directory."
      page = nil
      return
    }
    do {
      let catalog = try fixtures.load(root, name)
      caseNames = catalog.caseNames
      page = FunctionChangesPageModel(comparison: catalog.comparison)
      selectedCase = name
      errorText = nil
    } catch FunctionFixtureError.unknownCase(let name, let available) {
      caseNames = available
      page = nil
      errorText = "Unknown pinned fixture: \(name)"
    } catch {
      page = nil
      errorText = "Unable to load pinned fixture: \(error)"
    }
  }
}
