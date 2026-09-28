import SwiftUI

struct FunctionChangesFixtureView: View {
  @State var model: FunctionChangesFixtureModel

  var body: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          examplePicker
          if model.canRetry { retryButton }
          contextLabel.fixedSize(horizontal: true, vertical: false)
        }
        VStack(alignment: .leading, spacing: 8) {
          examplePicker
          HStack {
            if model.canRetry { retryButton }
            Spacer()
            contextLabel
          }
        }
      }
      .font(DesignTokens.FunctionTree.bodyFont)
      .foregroundStyle(DesignTokens.FunctionTree.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 24)
      .padding(.vertical, 10)
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

  private var examplePicker: some View {
    HStack {
      Text(model.pickerTitle)
      if model.hasCases {
        Picker(model.pickerTitle, selection: $model.caseSelection) {
          ForEach(model.caseNames, id: \.self) { name in Text(name).tag(name) }
        }
        .labelsHidden()
        .help("Recorded test data, not a live comparison")
        .frame(maxWidth: 290)
      }
    }
  }

  private var retryButton: some View {
    Button(model.retryButtonText) { model.retryTapped() }
  }

  private var contextLabel: some View {
    Text(model.feedContextText)
      .font(DesignTokens.FunctionTree.smallFont)
      .foregroundStyle(DesignTokens.FunctionTree.changed)
      .fixedSize(horizontal: false, vertical: true)
  }
}
