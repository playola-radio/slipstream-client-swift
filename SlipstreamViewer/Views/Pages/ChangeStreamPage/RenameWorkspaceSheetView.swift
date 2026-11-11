import SwiftUI

struct RenameWorkspaceSheetView: View {
  @Bindable var model: WorkspaceNamingModel
  @FocusState private var isFieldFocused: Bool
  @State private var selection: TextSelection?

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.RenameDialog.gap) {
      HStack(spacing: DesignTokens.RenameDialog.headerGap) {
        IconView(icon: DesignTokens.RenameDialog.headerIcon)
        Text(model.titleText)
          .font(DesignTokens.RenameDialog.titleFont)
          .foregroundStyle(DesignTokens.RenameDialog.titleColor)
      }
      field
      if let errorText = model.errorText {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.RenameDialog.errorGap) {
          IconView(icon: DesignTokens.RenameDialog.errorIcon)
          Text(errorText)
            .font(DesignTokens.RenameDialog.errorFont)
            .foregroundStyle(DesignTokens.RenameDialog.errorColor)
            .lineSpacing(DesignTokens.RenameDialog.errorLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let failureDetail = model.failureDetail {
        detail(failureDetail)
      }
      if model.isHelperShown {
        Text(model.helperText)
          .font(DesignTokens.RenameDialog.helperFont)
          .foregroundStyle(DesignTokens.RenameDialog.helperColor)
          .lineSpacing(DesignTokens.RenameDialog.helperLineSpacing)
          .fixedSize(horizontal: false, vertical: true)
      }
      buttons
    }
    .padding(DesignTokens.RenameDialog.padding)
    .frame(width: DesignTokens.RenameDialog.width)
    .background(DesignTokens.RenameDialog.fill)
    .interactiveDismissDisabled(model.isSaving)
    .onExitCommand { model.cancelTapped() }
    .onAppear {
      isFieldFocused = true
      selection = TextSelection(range: model.draft.startIndex..<model.draft.endIndex)
    }
  }

  private var field: some View {
    TextField("", text: $model.draft, selection: $selection)
      .textFieldStyle(.plain)
      .font(DesignTokens.RenameDialog.fieldFont)
      .foregroundStyle(DesignTokens.RenameDialog.fieldTextColor(isDisabled: model.isFieldDisabled))
      .focused($isFieldFocused)
      .disabled(model.isFieldDisabled)
      .onSubmit { Task { await model.renameConfirmed() } }
      .padding(.horizontal, DesignTokens.RenameDialog.fieldHorizontalPadding)
      .frame(height: DesignTokens.RenameDialog.fieldHeight)
      .background(
        DesignTokens.RenameDialog.fieldFill,
        in: RoundedRectangle(cornerRadius: DesignTokens.RenameDialog.fieldRadius))
      .overlay {
        RoundedRectangle(cornerRadius: DesignTokens.RenameDialog.fieldRadius)
          .stroke(
            DesignTokens.RenameDialog.fieldStroke(isInvalid: model.isFieldInvalid, isDisabled: model.isFieldDisabled))
      }
  }

  private func detail(_ text: String) -> some View {
    HStack(alignment: .top, spacing: DesignTokens.RenameDialog.detailGap) {
      Text(text)
        .font(DesignTokens.RenameDialog.detailFont)
        .foregroundStyle(DesignTokens.RenameDialog.detailColor)
        .lineSpacing(DesignTokens.RenameDialog.detailLineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button { model.copyErrorTapped() } label: {
        HStack(spacing: DesignTokens.RenameDialog.copyGap) {
          IconView(icon: DesignTokens.RenameDialog.copyIcon)
          Text(model.copyButtonTitle)
            .font(DesignTokens.RenameDialog.copyFont)
            .foregroundStyle(DesignTokens.RenameDialog.copyColor)
        }
        .padding(DesignTokens.RenameDialog.copyInsets)
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.RenameDialog.copyRadius)
            .stroke(DesignTokens.RenameDialog.copyStroke)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(DesignTokens.RenameDialog.detailInsets)
    .background(
      DesignTokens.RenameDialog.detailFill,
      in: RoundedRectangle(cornerRadius: DesignTokens.RenameDialog.detailRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.RenameDialog.detailRadius)
        .stroke(DesignTokens.RenameDialog.detailStroke)
    }
  }

  private var buttons: some View {
    HStack(spacing: DesignTokens.RenameDialog.buttonGap) {
      Spacer()
      if model.isCloseOnly {
        Button { model.closeTapped() } label: {
          buttonLabel(model.closeButtonTitle, colors: DesignTokens.RenameDialog.primaryButton(isDimmed: false))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
      } else {
        Button { model.cancelTapped() } label: {
          buttonLabel(model.cancelButtonTitle, colors: DesignTokens.RenameDialog.cancelButton(isDimmed: model.isSaving))
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        Button { Task { await model.renameConfirmed() } } label: {
          buttonLabel(
            model.primaryButtonTitle, colors: DesignTokens.RenameDialog.primaryButton(isDimmed: model.isPrimaryDimmed),
            isSpinnerShown: model.isSaving)
        }
        .buttonStyle(.plain)
        .disabled(!model.isRenameEnabled)
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func buttonLabel(
    _ title: String, colors: DesignTokens.RenameDialog.ButtonColors, isSpinnerShown: Bool = false
  ) -> some View {
    HStack(spacing: DesignTokens.RenameDialog.buttonContentGap) {
      if isSpinnerShown {
        SpinnerView(spinner: DesignTokens.RenameDialog.savingSpinner)
      }
      Text(title)
        .font(DesignTokens.RenameDialog.buttonFont)
        .foregroundStyle(colors.text)
    }
    .padding(.horizontal, DesignTokens.RenameDialog.buttonHorizontalPadding)
    .frame(height: DesignTokens.RenameDialog.buttonHeight)
    .background(colors.fill, in: RoundedRectangle(cornerRadius: DesignTokens.RenameDialog.buttonRadius))
    .contentShape(Rectangle())
  }
}
