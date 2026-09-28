import SwiftUI

struct FunctionChangesFixtureView: View {
  @State var model: FunctionChangesFixtureModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(model.pickerTitle)
        if !model.caseNames.isEmpty {
          Picker(model.pickerTitle, selection: $model.caseSelection) {
            ForEach(model.caseNames, id: \.self) { name in Text(name).tag(name) }
          }
          .labelsHidden()
          .help("Recorded test data, not a live comparison")
          .frame(width: 290)
        }
        if model.canRetry {
          Button(model.retryButtonText) { model.retryTapped() }
        }
        Spacer()
        Text(model.feedContextText)
          .font(DesignTokens.FunctionTree.smallFont)
          .foregroundStyle(DesignTokens.FunctionTree.changed)
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
        Text(model.errorText ?? model.loadingText)
          .font(DesignTokens.FunctionTree.bodyFont)
          .foregroundStyle(DesignTokens.FunctionTree.changed)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(DesignTokens.FunctionTree.background)
      }
    }
    .task { model.viewAppeared() }
  }
}
