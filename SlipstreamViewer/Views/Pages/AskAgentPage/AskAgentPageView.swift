import AppKit
import SwiftUI

struct AskAgentPageView: View {
  @Bindable var model: AskAgentPageModel
  var dismiss: () -> Void
  var submit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Ask.gap) {
      HStack(spacing: DesignTokens.Ask.gap) {
        Text(model.title).font(DesignTokens.Ask.titleFont).foregroundStyle(DesignTokens.Ask.titleColor)
        Spacer()
        Button(action: dismiss) {
          AskIcon(name: "X", color: DesignTokens.Ask.closeColor)
        }
        .accessibilityLabel(model.closeText)
      }
      QuestionEditor(model: model, dismiss: dismiss)
        .frame(height: DesignTokens.Ask.editorHeight)
        .background(DesignTokens.Ask.editorFill, in: RoundedRectangle(cornerRadius: DesignTokens.Ask.controlRadius))
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.Ask.controlRadius)
            .strokeBorder(DesignTokens.Ask.stroke, lineWidth: DesignTokens.Ask.strokeWidth)
        }
      if model.isPausedNoticeVisible {
        pausedNotice
      } else if let text = model.askNoticeText {
        Text(text)
          .font(DesignTokens.Ask.contextFont)
          .foregroundStyle(DesignTokens.Ask.savedLabel)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: DesignTokens.Ask.actionGap) {
        Text(model.contextText)
          .font(DesignTokens.Ask.contextFont)
          .foregroundStyle(DesignTokens.Ask.contextColor)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(model.contextText)
        Spacer(minLength: 0)
        Button(model.cancelText, action: dismiss)
          .font(DesignTokens.Ask.bodyFont)
          .foregroundStyle(DesignTokens.Ask.cancelColor)
        Button(action: submit) {
          HStack(spacing: DesignTokens.Ask.controlGap) {
            Text(model.askText).font(DesignTokens.Ask.sendFont)
            AskIcon(name: "ArrowUp", color: DesignTokens.Ask.sendText)
          }
          .foregroundStyle(DesignTokens.Ask.sendText)
          .padding(.vertical, DesignTokens.Ask.sendVerticalPadding)
          .padding(.horizontal, DesignTokens.Ask.sendHorizontalPadding)
          .background(DesignTokens.Ask.sendFill, in: RoundedRectangle(cornerRadius: DesignTokens.Ask.controlRadius))
        }
        .disabled(!model.canSubmit)
        .opacity(DesignTokens.Ask.sendOpacity(isEnabled: model.canSubmit))
      }
      savedQuestions
    }
    .buttonStyle(.plain)
    .padding(.top, DesignTokens.Ask.topPadding)
    .padding([.horizontal, .bottom], DesignTokens.Ask.padding)
    .background(DesignTokens.Ask.fill, in: RoundedRectangle(cornerRadius: DesignTokens.Ask.radius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.Ask.radius)
        .strokeBorder(DesignTokens.Ask.stroke, lineWidth: DesignTokens.Ask.strokeWidth)
    }
    .onExitCommand(perform: dismiss)
    .alert(model.errorTitle, isPresented: $model.isErrorPresented) {
      Button(model.errorDismissText, role: .cancel) {}
    } message: {
      Text(model.errorMessage)
    }
    .task { await model.viewAppeared() }
  }

  private var pausedNotice: some View {
    HStack(spacing: DesignTokens.Ask.pausedNoticeGap) {
      IconView(icon: DesignTokens.Ask.pausedNoticeIcon)
      Text(model.pausedNoticeText)
        .font(DesignTokens.Ask.contextFont)
        .foregroundStyle(model.pausedNoticeColor)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button { Task { await model.recordTapped() } } label: {
        HStack(spacing: DesignTokens.Ask.recordGap) {
          if model.isRecordDisabled {
            SpinnerView(spinner: DesignTokens.Ask.recordSpinner)
          } else {
            IconView(icon: DesignTokens.Ask.recordIcon)
          }
          Text(model.recordButtonText).font(DesignTokens.Ask.recordFont)
        }
        .foregroundStyle(DesignTokens.Ask.recordColor)
        .padding(.vertical, DesignTokens.Ask.recordVerticalPadding)
        .padding(.horizontal, DesignTokens.Ask.recordHorizontalPadding)
        .background(DesignTokens.Ask.recordFill, in: RoundedRectangle(cornerRadius: DesignTokens.Ask.controlRadius))
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.Ask.controlRadius)
            .strokeBorder(DesignTokens.Ask.recordStroke, lineWidth: DesignTokens.Sidebar.RowAction.strokeWidth)
        }
      }
      .disabled(model.isRecordDisabled)
      .opacity(DesignTokens.Sidebar.RowAction.opacity(isWorking: model.isRecordDisabled))
    }
    .padding(.vertical, DesignTokens.Ask.pausedNoticeVerticalPadding)
    .padding(.horizontal, DesignTokens.Ask.pausedNoticeHorizontalPadding)
    .background(DesignTokens.Ask.pausedNoticeFill, in: RoundedRectangle(cornerRadius: DesignTokens.Ask.controlRadius))
  }

  private var savedQuestions: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Ask.smallGap) {
      Text(model.savedQuestionsText)
        .font(DesignTokens.Ask.savedFont)
        .foregroundStyle(DesignTokens.Ask.savedLabel)
      HStack(spacing: DesignTokens.Ask.controlGap) {
        Button { model.menuTapped() } label: {
          HStack(spacing: DesignTokens.Ask.controlGap) {
            Text(model.selectedPreset).frame(maxWidth: .infinity, alignment: .leading)
            AskIcon(name: model.dropdownIcon, color: DesignTokens.Ask.dropdownIcon)
          }
          .font(DesignTokens.Ask.bodyFont)
          .foregroundStyle(DesignTokens.Ask.editorText)
          .padding(.vertical, DesignTokens.Ask.controlVerticalPadding)
          .padding(.horizontal, DesignTokens.Ask.controlHorizontalPadding)
          .background(DesignTokens.Ask.dropdownFill, in: RoundedRectangle(cornerRadius: DesignTokens.Ask.controlRadius))
          .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Ask.controlRadius).strokeBorder(DesignTokens.Ask.dropdownStroke)
          }
        }
        .accessibilityLabel(model.savedQuestionsText)
        .accessibilityValue(model.selectedPreset)
        Button { model.appendTapped() } label: {
          Text(model.appendText)
            .font(DesignTokens.Ask.appendFont)
            .foregroundStyle(DesignTokens.Ask.appendText)
            .padding(.vertical, DesignTokens.Ask.controlVerticalPadding)
            .padding(.horizontal, DesignTokens.Ask.controlHorizontalPadding)
            .background(DesignTokens.Ask.appendFill, in: RoundedRectangle(cornerRadius: DesignTokens.Ask.controlRadius))
        }
        .disabled(model.isEditingDisabled)
      }
      if model.isMenuOpen { menu }
    }
    .padding(.top, DesignTokens.Ask.savedTopPadding)
    .overlay(alignment: .top) { Rectangle().fill(DesignTokens.Ask.divider).frame(height: 1) }
  }

  private var menu: some View {
    VStack(spacing: 0) {
      ForEach(model.options, id: \.self) { option in
        Button { model.savedQuestionSelected(option) } label: {
          HStack(spacing: DesignTokens.Ask.controlGap) {
            Text(option).frame(maxWidth: .infinity, alignment: .leading)
            if model.isSelected(option) { AskIcon(name: "Check", color: DesignTokens.Ask.contextColor) }
          }
          .font(DesignTokens.Ask.bodyFont)
          .foregroundStyle(DesignTokens.Ask.menuText)
          .padding(.vertical, DesignTokens.Ask.menuVerticalPadding)
          .padding(.horizontal, DesignTokens.Ask.menuHorizontalPadding)
          .background(model.optionFill(option), in: RoundedRectangle(cornerRadius: DesignTokens.Ask.menuItemRadius))
          .contentShape(Rectangle())
        }
        .disabled(model.isAddingPreset)
      }
      Group {
        if model.isAddingPreset {
          HStack(spacing: DesignTokens.Ask.controlGap) {
            TextField(model.addText, text: $model.newPreset)
              .textFieldStyle(.plain)
              .disabled(model.isSavingPreset)
              .onSubmit { Task { await model.savePresetTapped() } }
            Button(model.saveText) { Task { await model.savePresetTapped() } }
              .disabled(!model.canSavePreset)
            Button(model.cancelText) { model.cancelPresetTapped() }
              .disabled(model.isSavingPreset)
          }
        } else {
          Button { model.addQuestionTapped() } label: {
            HStack(spacing: DesignTokens.Ask.controlGap) {
              AskIcon(name: "Plus", color: DesignTokens.Ask.contextColor)
              Text(model.addText)
              Spacer()
            }
            .contentShape(Rectangle())
          }
          .disabled(!model.presetsLoaded)
        }
      }
      .font(DesignTokens.Ask.bodyFont)
      .foregroundStyle(DesignTokens.Ask.contextColor)
      .padding(DesignTokens.Ask.menuHorizontalPadding)
      .overlay(alignment: .top) { Rectangle().fill(DesignTokens.Ask.menuDivider).frame(height: 1) }
    }
    .padding(DesignTokens.Ask.menuPadding)
    .background(DesignTokens.Ask.menuFill, in: RoundedRectangle(cornerRadius: DesignTokens.Ask.controlRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.Ask.controlRadius).strokeBorder(DesignTokens.Ask.menuStroke)
    }
  }
}

private struct AskIcon: View {
  let name: String
  let color: Color
  var body: some View {
    Image(name).resizable().frame(width: DesignTokens.Ask.iconSize, height: DesignTokens.Ask.iconSize)
      .foregroundStyle(color).accessibilityHidden(true)
  }
}

private struct QuestionEditor: NSViewRepresentable {
  let model: AskAgentPageModel
  var dismiss: () -> Void
  @Environment(\.fontScale) private var fontScale

  func makeCoordinator() -> Coordinator { Coordinator(model: model, dismiss: dismiss) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    let text = QuestionTextView()
    text.isRichText = false
    text.drawsBackground = false
    text.textColor = NSColor(DesignTokens.Ask.editorText)
    text.insertionPointColor = NSColor(DesignTokens.Ask.editorText)
    text.textContainerInset = NSSize(width: DesignTokens.Ask.editorPadding, height: DesignTokens.Ask.editorPadding)
    text.textContainer?.lineFragmentPadding = 0
    text.textContainer?.widthTracksTextView = true
    text.isVerticallyResizable = true
    text.autoresizingMask = [.width]
    applyTypography(to: text)
    context.coordinator.fontScale = fontScale
    text.setAccessibilityLabel("Question")
    text.delegate = context.coordinator
    scroll.documentView = text
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? NSTextView else { return }
    if text.string != model.draft { text.string = model.draft }
    text.isEditable = !model.isEditingDisabled
    if context.coordinator.fontScale != fontScale {
      context.coordinator.fontScale = fontScale
      applyTypography(to: text)
      if text.window?.firstResponder === text { text.scrollRangeToVisible(text.selectedRange()) }
    }
    if context.coordinator.caretRevision != model.caretRevision {
      context.coordinator.caretRevision = model.caretRevision
      text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
      text.scrollRangeToVisible(text.selectedRange())
      text.window?.makeFirstResponder(text)
    }
  }

  private func applyTypography(to text: NSTextView) {
    let size = DesignTokens.Ask.editorFontSize * fontScale
    let font = NSFont(name: "Geist", size: size) ?? .systemFont(ofSize: size)
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = DesignTokens.Ask.editorLineHeight * fontScale
    paragraph.maximumLineHeight = DesignTokens.Ask.editorLineHeight * fontScale
    text.font = font
    text.defaultParagraphStyle = paragraph
    text.typingAttributes[.paragraphStyle] = paragraph
    text.typingAttributes[.font] = font
    if let storage = text.textStorage {
      storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    let model: AskAgentPageModel
    var caretRevision = 0
    var fontScale: CGFloat = 1
    let dismiss: () -> Void
    init(model: AskAgentPageModel, dismiss: @escaping () -> Void) {
      self.model = model
      self.dismiss = dismiss
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
      dismiss()
      return true
    }
    func textDidChange(_ notification: Notification) {
      guard let text = notification.object as? NSTextView else { return }
      model.draftChanged(text.string)
    }
  }
}

private final class QuestionTextView: NSTextView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }
}
