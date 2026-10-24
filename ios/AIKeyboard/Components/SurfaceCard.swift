//
//  SurfaceCard.swift
//  墨语 · 宿主 App 组件
//
//  通用卡片容器（契约：design/组件库.md §4.1）。
//  主 App 的「灰底白卡」语言全部由它承载：plain / elevated / glass 三种。
//
//  用法：
//      SurfaceCard { ... }
//      SurfaceCard(style: .glass) { ... }
//      SurfaceCard(onTap: { ... }) { ... }
//
import SwiftUI

/// 通用卡片容器。
///
/// - plain：`Theme.surface` 底，无阴影（iOS 设置页的卡片语言）。
/// - elevated：加 `Theme.Shadow.card` 投影，用于需要浮起的强调卡片。
/// - glass：走 `GlassSurface(.card)`（全 App 唯一允许使用材质的组件）。
struct SurfaceCard<Content: View>: View {

    /// 卡片风格。
    enum Style: Equatable {
        case plain
        case elevated
        case glass
    }

    private let style: Style
    private let padding: CGFloat
    private let cornerRadius: CGFloat
    private let onTap: (() -> Void)?
    private let content: Content

    init(
        style: Style = .plain,
        padding: CGFloat = Theme.Spacing.xl,
        cornerRadius: CGFloat = Theme.Radius.card,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.onTap = onTap
        self.content = content()
    }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    cardBody
                }
                .buttonStyle(SurfaceCardPressStyle(cornerRadius: cornerRadius))
            } else {
                cardBody
            }
        }
    }

    /// 卡片主体：内容 + 内边距 + 背景 + 圆角 + 投影。
    private var cardBody: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundLayer)
            .clipShape(shape)
            .modifier(SurfaceCardElevation(isElevated: style == .elevated))
    }

    /// 背景层。
    @ViewBuilder
    private var backgroundLayer: some View {
        if style == .glass {
            GlassSurface(level: .card, cornerRadius: cornerRadius, content: { Color.clear })
        } else {
            Theme.surface
        }
    }

    /// 圆角形状（统一 continuous，禁止 iOS 17 的 `.rect(cornerRadius:)`）。
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// 契约里的旧名 `CapCard` 保留为类型别名，避免历史代码 / 文档引用失效。
typealias CapCard<Content: View> = SurfaceCard<Content>

/// 卡片投影（仅 elevated 生效）。
private struct SurfaceCardElevation: ViewModifier {

    let isElevated: Bool

    func body(content: Content) -> some View {
        if isElevated {
            content.shadow(
                color: Theme.textPrimary.opacity(Theme.Shadow.card.opacity),
                radius: Theme.Shadow.card.blur,
                x: 0,
                y: Theme.Shadow.card.y
            )
        } else {
            content
        }
    }
}

/// 卡片被当作按钮时的按压反馈。
private struct SurfaceCardPressStyle: ButtonStyle {

    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? Theme.surfaceElevated : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(Theme.Motion.fastAnimation, value: configuration.isPressed)
    }
}

#if DEBUG
struct SurfaceCard_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            AppColor.pageBackground.ignoresSafeArea()
            VStack(spacing: AppMetrics.sectionGap) {
                SurfaceCard {
                    Text("plain 卡片")
                        .font(AppFont.headline)
                        .foregroundColor(Theme.textPrimary)
                }
                SurfaceCard(style: .elevated) {
                    Text("elevated 卡片")
                        .font(AppFont.headline)
                        .foregroundColor(Theme.textPrimary)
                }
                SurfaceCard(style: .glass) {
                    Text("glass 卡片")
                        .font(AppFont.headline)
                        .foregroundColor(Theme.textPrimary)
                }
            }
            .padding(AppMetrics.pageInset)
        }
    }
}
#endif
