//
//  StepCard.swift
//  墨语 · 宿主 App 组件
//
//  分步引导卡（契约：design/组件库.md §4.8）。
//  安装 / 续签指南的主视觉，也用于引导流程的说明页。
//
import SwiftUI

/// 单个步骤卡：序号 + 标题 + 说明 + 可选代码块 + 可选按钮。
struct StepCard: View {

    private let index: Int
    private let title: String
    private let detail: String
    private let icon: String
    private let codeSnippet: String?
    private let isDone: Bool
    private let actionTitle: String?
    private let onAction: (() -> Void)?

    /// 代码块复制后的短暂提示。
    @State private var didCopy = false

    init(
        index: Int,
        title: String,
        detail: String,
        icon: String,
        codeSnippet: String? = nil,
        isDone: Bool = false,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.index = index
        self.title = title
        self.detail = detail
        self.icon = icon
        self.codeSnippet = codeSnippet
        self.isDone = isDone
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppMetrics.rowGap) {
            indexBadge

            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                HStack(spacing: AppMetrics.tightGap) {
                    IconGlyph(
                        symbol: icon,
                        fallback: "",
                        size: AppMetrics.glyphSizeSmall,
                        weight: .semibold,
                        tint: Theme.textSecondary
                    )
                    Text(title)
                        .font(AppFont.headline)
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(detail)
                    .font(AppFont.body)
                    .foregroundColor(Theme.textSecondary)
                    .lineSpacing(AppMetrics.hairGap)
                    .fixedSize(horizontal: false, vertical: true)

                if let codeSnippet {
                    codeBlock(codeSnippet)
                }

                if let actionTitle, let onAction {
                    SecondaryButton(title: actionTitle, tone: .neutral, size: .small, action: onAction)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(AppMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous))
    }

    /// 左侧序号圆（完成态为绿底白勾）。
    private var indexBadge: some View {
        Group {
            if isDone {
                Circle()
                    .fill(Theme.success)
                    .overlay(
                        IconGlyph(
                            symbol: "checkmark",
                            fallback: "✓",
                            size: AppMetrics.glyphSizeSmall - AppMetrics.hairGap,
                            weight: .bold,
                            tint: Theme.textOnAccent
                        )
                    )
            } else {
                Circle()
                    .fill(AppColor.accentWash)
                    .overlay(
                        Text("\(index)")
                            .font(.system(size: AppMetrics.glyphSizeSmall - AppMetrics.hairGap, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    )
            }
        }
        .frame(width: AppMetrics.stepIndexSize, height: AppMetrics.stepIndexSize)
        .accessibilityLabel(Text(isDone ? "第 \(index) 步已完成" : "第 \(index) 步"))
    }

    /// 可复制的代码块。
    private func codeBlock(_ snippet: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Text(snippet)
                .font(AppFont.monospacedFootnote)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppMetrics.rowVPadding)
                .padding(.trailing, AppMetrics.heroIcon + AppMetrics.blockGap)

            Button {
                UIPasteboard.general.string = snippet
                Haptics.success()
                withAnimation(Theme.Motion.fastAnimation) { didCopy = true }
            } label: {
                Text(didCopy ? "已复制" : "复制")
                    .font(AppFont.caption)
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, AppMetrics.tightGap)
                    .padding(.vertical, AppMetrics.hairGap)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(AppMetrics.tightGap)
            .accessibilityLabel(Text("复制这段内容"))
        }
        .background(
            RoundedRectangle(cornerRadius: AppMetrics.codeBlockRadius, style: .continuous)
                .fill(Theme.surfaceElevated)
        )
    }
}

/// 步骤之间的竖直连接线。
struct StepConnector: View {
    var body: some View {
        Rectangle()
            .fill(AppColor.cardStroke)
            .frame(width: AppMetrics.hairline, height: AppMetrics.stepConnectorHeight)
            .padding(.leading, AppMetrics.cardPadding + AppMetrics.stepIndexSize / 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
struct StepCard_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 0) {
                StepCard(
                    index: 1,
                    title: "准备签名方式",
                    detail: "有 Mac 用 Xcode 直接 Run；只有 Windows 就走 GitHub Actions 云编译。",
                    icon: "hammer",
                    isDone: true
                )
                StepConnector()
                StepCard(
                    index: 2,
                    title: "云端编译出 ipa",
                    detail: "推到私有仓库后，在 Actions 里跑 Build Unsigned IPA，下载产物。",
                    icon: "cloud",
                    codeSnippet: "AIKeyboard-unsigned.ipa",
                    actionTitle: "打开仓库设置"
                )
            }
            .padding(AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground)
    }
}
#endif
