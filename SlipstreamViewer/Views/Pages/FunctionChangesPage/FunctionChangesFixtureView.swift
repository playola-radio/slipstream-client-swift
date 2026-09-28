import SwiftUI

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
