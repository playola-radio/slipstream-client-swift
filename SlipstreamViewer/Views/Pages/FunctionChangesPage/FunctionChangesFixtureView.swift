import Foundation
import Observation
import SlipstreamCore
import SwiftUI

@MainActor
@Observable
final class FunctionChangesFixtureModel: ViewModel {
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
      let cases = root.appending(path: "cases")
      caseNames = try FileManager.default.contentsOfDirectory(
        at: cases, includingPropertiesForKeys: nil
      )
      .filter { FileManager.default.fileExists(atPath: $0.appending(path: "expected.json").path) }
      .map(\.lastPathComponent)
      .sorted()
      guard caseNames.contains(name) else {
        page = nil
        errorText = "Unknown pinned fixture: \(name)"
        return
      }
      let data = try Data(contentsOf: cases.appending(path: name).appending(path: "expected.json"))
      page = FunctionChangesPageModel(comparison: try InterfaceComparison.decode(data))
      selectedCase = name
      errorText = nil
    } catch {
      page = nil
      errorText = "Unable to load pinned fixture: \(error)"
    }
  }
}

struct FunctionChangesFixtureView: View {
  @State var model: FunctionChangesFixtureModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(model.pickerTitle)
        Picker(model.pickerTitle, selection: $model.selectedCase) {
          ForEach(model.caseNames, id: \.self) { name in Text(name).tag(name) }
        }
        .labelsHidden()
        .frame(width: 290)
        .onChange(of: model.selectedCase) { _, name in model.caseSelected(name) }
        Spacer()
        Text("PIN b0688d7 · Fixture data only")
      }
      .font(DesignTokens.FunctionTree.bodyFont)
      .foregroundStyle(DesignTokens.FunctionTree.secondary)
      .padding(.horizontal, 24)
      .frame(height: 44)
      .background(DesignTokens.FunctionTree.headerFill)
      if let page = model.page {
        FunctionChangesPageView(model: page)
          .id(page)
      } else {
        Text(model.errorText ?? "Loading fixture…")
          .font(DesignTokens.FunctionTree.bodyFont)
          .foregroundStyle(DesignTokens.FunctionTree.changed)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(DesignTokens.FunctionTree.background)
      }
    }
    .task { model.viewAppeared() }
  }
}
