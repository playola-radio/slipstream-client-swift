import SwiftUI

struct FunctionChangesLiveView: View {
  @State var model: FunctionChangesLiveModel
  let close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(model.headingText)
          .font(DesignTokens.FunctionTree.bodyFont)
        Spacer()
        if model.isLoading {
          Text(model.loadingText)
            .foregroundStyle(DesignTokens.FunctionTree.secondary)
        }
        if model.canRetry {
          Button(model.retryText) { Task { await model.retryTapped() } }
        }
        Button("Close", action: close)
      }
      .font(DesignTokens.FunctionTree.bodyFont)
      .foregroundStyle(DesignTokens.FunctionTree.secondary)
      .buttonStyle(.plain)
      .padding(.horizontal, 24)
      .padding(.vertical, 10)
      .background(DesignTokens.FunctionTree.headerFill)
      if let status = model.statusText {
        Text(status)
          .font(DesignTokens.FunctionTree.smallFont)
          .foregroundStyle(DesignTokens.FunctionTree.changed)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 24)
          .padding(.vertical, 8)
          .background(DesignTokens.FunctionTree.bannerFill)
      }
      if let page = model.page {
        FunctionChangesPageView(model: page)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Text(model.statusText == nil ? model.loadingText : "Comparison unavailable")
          .font(DesignTokens.FunctionTree.bodyFont)
          .foregroundStyle(DesignTokens.FunctionTree.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(DesignTokens.FunctionTree.background)
      }
    }
    .task { await model.viewAppeared() }
    .onDisappear { model.viewDisappeared() }
  }
}
