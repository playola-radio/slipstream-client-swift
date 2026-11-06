import SwiftUI

/// A reply: prose with inline markdown, and fenced code in Geist Mono.
struct MarkdownText: View {
  let text: String
  @Environment(\.fontScale) private var fontScale

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Chat.Transcript.gap) {
      ForEach(Array(ChatTabModel.markdownBlocks(text).enumerated()), id: \.offset) { _, block in
        switch block {
        case .prose(let prose):
          Text(DesignTokens.Chat.Paragraph.styled(prose, scale: fontScale))
            .font(DesignTokens.Chat.Paragraph.font)
            .foregroundStyle(DesignTokens.Chat.Paragraph.color)
            .lineSpacing(DesignTokens.Chat.Paragraph.lineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let code):
          ScrollView(.horizontal) {
            Text(code)
              .font(DesignTokens.Chat.CodeBlock.font)
              .foregroundStyle(DesignTokens.Chat.CodeBlock.color)
              .textSelection(.enabled)
              .padding(DesignTokens.Chat.CodeBlock.padding)
          }
          .scrollIndicators(.hidden)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(DesignTokens.Chat.CodeBlock.fill,
            in: RoundedRectangle(cornerRadius: DesignTokens.Chat.CodeBlock.radius))
        }
      }
    }
  }
}
