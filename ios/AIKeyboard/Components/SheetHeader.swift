//
//  SheetHeader.swift
//  墨语 · 宿主 App 组件
//
//  Sheet 顶部标题栏（契约：design/组件库.md §3.7）。
//
import SwiftUI

/// Sheet 顶部：抓手 + 标题 + 副标题 + 关闭 / 右侧操作。
struct SheetHeader<Accessory: View>: View {

    private let title: String
    private let subtitle: String?
    private let showsClose: Bool
    private let onClose: (() -> Void)?
    private let accessory: Accessory

    init(
        title: String,
        subtitle: String? = nil,
        showsClose: Bool = true,
        onClose: (() -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsClose = showsClose
        self.onClose = onClose
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: AppMetrics.blockGap) {
            Capsule(style: .continuous)
                .fill(Theme.separator)
                .frame(width: AppMetrics.heroIcon - AppMetrics.stepIndexSize, height: AppMetrics.tightGap)
                .padding(.top, AppMetrics.blockGap)
                .accessibilityHidden(true)

            ZStack {
                VStack(spacing: AppMetrics.hairGap) {
                    Text(title)
                        .font(AppFont.headline)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppFont.caption)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }

                HStack {
                    Spacer()
                    if showsClose, let onClose {
                        Button(action: onClose) {
                            IconGlyph(
                                symbol: "xmark.circle.fill",
                                fallback: "×",
                                size: AppMetrics.glyphSize + AppMetrics.chipIconGap,
                                tint: Theme.textTertiary
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel(Text("关闭"))
                    }
                }

                HStack {
                    accessory
                    Spacer()
                }
            }
            .frame(minHeight: AppMetrics.sheetHeaderHeight)
        }
        .padding(.horizontal, AppMetrics.cardPadding)
        .padding(.bottom, AppMetrics.blockGap)
        .background(Theme.surface)
    }
}

extension SheetHeader where Accessory == EmptyView {
    /// 没有右侧操作的便捷构造。
    init(title: String, subtitle: String? = nil, showsClose: Bool = true, onClose: (() -> Void)? = nil) {
        self.init(
            title: title,
            subtitle: subtitle,
            showsClose: showsClose,
            onClose: onClose,
            accessory: { EmptyView() }
        )
    }
}

#if DEBUG
struct SheetHeader_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: AppMetrics.sectionGap) {
            SheetHeader(title: "编辑服务商", subtitle: "DeepSeek 深度求索", onClose: {})
            SheetHeader(title: "Prompt 模板", onClose: {}) {
                Text("保存")
                    .font(AppFont.footnoteStrong)
                    .foregroundColor(Theme.accent)
            }
        }
        .background(AppColor.pageBackground)
    }
}
#endif
