//
//  StreamingText.swift
//  墨语 · 宿主 App 组件
//
//  流式文本展示（契约：design/组件库.md §3.4）。
//  自动滚到底部、尾部闪烁光标、空流时显示「正在思考…」。
//
import SwiftUI

/// 流式文本。
///
/// - `maxHeight` 传 0 或负数表示不限制高度（结果卡完成后展开全文时用）。
struct StreamingText: View {

    private let text: String
    private let isStreaming: Bool
    private let font: Font
    private let maxHeight: CGFloat
    private let onReachBottom: (() -> Void)?

    /// 光标明暗。
    @State private var cursorOn = true

    /// 减少动态效果时不闪。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 底部锚点标识。
    private static let bottomAnchor = "streaming-bottom"

    init(
        text: String,
        isStreaming: Bool,
        font: Font = .system(size: 16),
        maxHeight: CGFloat = 132,
        onReachBottom: (() -> Void)? = nil
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.font = font
        self.maxHeight = maxHeight
        self.onReachBottom = onReachBottom
    }

    var body: some View {
        Group {
            if text.isEmpty && isStreaming {
                thinkingIndicator
            } else {
                scrollableText
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(isStreaming ? "正在生成" : text))
    }

    // MARK: - 空流占位

    private var thinkingIndicator: some View {
        HStack(spacing: AppMetrics.tightGap) {
            ProgressDots()
            Text("正在思考…")
                .font(AppFont.caption)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: AppMetrics.thumbnailSize, alignment: .leading)
    }

    // MARK: - 正文

    private var scrollableText: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                    HStack(alignment: .bottom, spacing: AppMetrics.hairGap) {
                        Text(text)
                            .font(font)
                            .foregroundColor(Theme.textPrimary)
                            .lineSpacing(AppMetrics.chipIconGap)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if isStreaming {
                            cursor
                        }
                    }

                    Color.clear
                        .frame(height: AppMetrics.hairline)
                        .id(Self.bottomAnchor)
                }
            }
            .frame(maxHeight: maxHeight > 0 ? maxHeight : nil)
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: text) { _ in scrollToBottom(proxy, animated: true) }
        }
    }

    /// 尾部光标。
    private var cursor: some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: AppMetrics.hairline * 4, height: AppMetrics.glyphSize)
            .opacity(cursorOn ? 1 : 0.2)
            .onAppear {
                guard !reduceMotion else {
                    cursorOn = true
                    return
                }
                withAnimation(
                    .easeInOut(duration: Theme.Motion.streamCursorBlink)
                    .repeatForever(autoreverses: true)
                ) {
                    cursorOn = false
                }
            }
            .accessibilityHidden(true)
    }

    /// 滚到底部。
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
        if animated && !reduceMotion {
            withAnimation(Theme.Motion.normalAnimation, action)
        } else {
            action()
        }
        onReachBottom?()
    }
}

#if DEBUG
struct StreamingText_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
            SurfaceCard {
                StreamingText(text: "", isStreaming: true)
            }
            SurfaceCard {
                StreamingText(text: "好的，我把这句话改得更正式一些：本次会议定于周五下午三点召开，请准时参加。", isStreaming: true)
            }
            SurfaceCard {
                StreamingText(
                    text: "这是一段已经完成的长文本，用来检查展开后是否会限制高度。",
                    isStreaming: false,
                    maxHeight: 0
                )
            }
        }
        .padding()
        .background(AppColor.pageBackground)
    }
}
#endif
