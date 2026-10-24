//
//  GlassSurface.swift
//  墨语 · 宿主 App 组件
//
//  L1 原子组件：玻璃质感容器。
//  **全项目唯一允许出现 `.ultraThinMaterial` / `.thinMaterial` / `.regularMaterial` 的地方**（契约 §1.4）。
//  其它组件一律通过本组件表达玻璃效果，保证 iOS 16 降级与「降低透明度」无障碍分支只有一份实现。
//
import SwiftUI

/// 玻璃质感容器。
///
/// 层级对应 `design/tokens.json` 的 `material.bar / material.card / material.sheet`：
/// - `.bar`   → `.ultraThinMaterial` + 0.5pt `Theme.separator` 描边（候选栏 / AI 工具条 / 结果卡）
/// - `.card`  → `.thinMaterial` + 0.5pt 描边（主 App 卡片）
/// - `.sheet` → `.regularMaterial`，无描边（Sheet 背景）
///
/// 降级规则：
/// 1. 材质 API 在 iOS 16 已可用，**不需要版本分支**；
/// 2. 「降低透明度」开启时改用 `Theme.surface.opacity(0.94)`（tokens `material.*.ios16Fallback`）；
/// 3. 圆角一律用 `.clipShape(RoundedRectangle(…))`，**禁止** `.rect(cornerRadius:)`（iOS 17 API）。
struct GlassSurface<Content: View>: View {

    /// 玻璃层级。
    enum Level: Equatable {
        case bar
        case card
        case sheet
    }

    /// 玻璃层级。
    private let level: Level

    /// 圆角半径。
    private let cornerRadius: CGFloat

    /// 是否绘制顶部高光（Liquid Glass 意象）。
    private let showHighlight: Bool

    /// 内容。
    private let content: Content

    /// 「降低透明度」无障碍开关。
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        level: Level = .bar,
        cornerRadius: CGFloat = Theme.Radius.card,
        showHighlight: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.level = level
        self.cornerRadius = cornerRadius
        self.showHighlight = showHighlight
        self.content = content()
    }

    var body: some View {
        content
            .background(backing)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(strokeOverlay)
            .overlay(highlightOverlay)
    }

    // MARK: - 底层材质

    /// 背景：降低透明度时退化为不透明底，否则使用对应层级的 Material。
    @ViewBuilder
    private var backing: some View {
        if reduceTransparency {
            Theme.surface.opacity(0.94)
        } else {
            switch level {
            case .bar:
                Rectangle().fill(.ultraThinMaterial)
            case .card:
                Rectangle().fill(.thinMaterial)
            case .sheet:
                Rectangle().fill(.regularMaterial)
            }
        }
    }

    // MARK: - 描边

    /// 0.5pt 描边（`.sheet` 不描边）。
    @ViewBuilder
    private var strokeOverlay: some View {
        if level == .sheet {
            EmptyView()
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: AppMetrics.hairline)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 顶部高光

    /// 顶部 45% 的白色渐变高光（tokens `material.highlight`）。
    @ViewBuilder
    private var highlightOverlay: some View {
        if showHighlight && !reduceTransparency {
            GeometryReader { proxy in
                LinearGradient(
                    colors: [AppColor.highlightTop, AppColor.highlightBottom],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(height: proxy.size.height * 0.45)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

#if DEBUG
struct GlassSurface_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            AppColor.pageBackground.ignoresSafeArea()
            VStack(spacing: AppMetrics.blockGap) {
                GlassSurface(level: .bar) {
                    Text("工具条玻璃")
                        .font(AppFont.body)
                        .padding(AppMetrics.cardPadding)
                }
                GlassSurface(level: .card, showHighlight: false) {
                    Text("卡片玻璃")
                        .font(AppFont.body)
                        .padding(AppMetrics.cardPadding)
                }
            }
            .padding(AppMetrics.pageInset)
        }
    }
}
#endif
