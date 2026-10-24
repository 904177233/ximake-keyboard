//
//  KMGlassSurface.swift
//  墨语（Moyu）键盘扩展 · 玻璃材质容器
//
//  模块职责：键盘域唯一的材质容器。候选栏 / AI 工具条 / AI 面板 / 结果卡片共用，
//            保证「键盘内只有这里能用 `.ultraThinMaterial`」这条硬契约。
//  设计依据：design/组件库.md「GlassSurface(level:.bar/.card/.sheet) 是唯一允许
//            `.ultraThinMaterial` 处，Reduce Transparency 降级 Theme.surface.opacity(0.94)，
//            禁 `.rect(cornerRadius:)`（iOS 17）」、design/键盘布局规范.md §8-④。
//  无障碍：Reduce Transparency 时改用不透明表面色，保证文字对比度。
//

import SwiftUI

/// 玻璃材质层级。
enum KMGlassLevel {
    /// 工具条 / 候选栏（最薄，需要透出键盘背景）。
    case bar
    /// 卡片（默认）。
    case card
    /// 面板 / Sheet（最厚）。
    case sheet
}

/// 玻璃材质容器。
struct KMGlassSurface<Content: View>: View {

    /// 材质层级。
    let level: KMGlassLevel

    /// 圆角。
    let cornerRadius: CGFloat

    /// 是否显示顶部高光。
    let showsHighlight: Bool

    /// 内容。
    @ViewBuilder let content: Content

    /// 是否开启「减弱透明度」。
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// 创建玻璃容器。
    /// - Parameters:
    ///   - level: 材质层级。
    ///   - cornerRadius: 圆角。
    ///   - showsHighlight: 是否显示顶部高光。
    ///   - content: 内容构建器。
    init(
        level: KMGlassLevel = .card,
        cornerRadius: CGFloat = Theme.Radius.card,
        showsHighlight: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.level = level
        self.cornerRadius = cornerRadius
        self.showsHighlight = showsHighlight
        self.content = content()
    }

    var body: some View {
        content
            .background(backgroundLayer)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .topLeading) { highlightLayer }
            .overlay(borderLayer)
    }

    /// 材质底层。
    @ViewBuilder
    private var backgroundLayer: some View {
        if reduceTransparency {
            Theme.surface.opacity(Theme.MaterialToken.barFallbackAlpha)
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

    /// 顶部高光（模拟玻璃的反光）。
    @ViewBuilder
    private var highlightLayer: some View {
        if showsHighlight && !reduceTransparency {
            GeometryReader { proxy in
                LinearGradient(
                    colors: [
                        Color.white.opacity(KMGlassMetrics.highlightOpacity),
                        Color.white.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(height: proxy.size.height * KMGlassMetrics.highlightHeightRatio)
            }
            .allowsHitTesting(false)
        }
    }

    /// 0.5pt 描边。
    private var borderLayer: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Theme.separator, lineWidth: Theme.MaterialToken.strokeWidth)
            .allowsHitTesting(false)
    }
}

/// 玻璃高光的几何常量。
///
/// 说明：Swift 不允许泛型类型内声明 `static stored property`
///（`static stored properties not supported in generic types`），
/// 而 `KMGlassSurface` 是泛型，故把这两个常量移到泛型外部的独立类型里。
private enum KMGlassMetrics {

    /// 顶部高光高度占容器比例（tokens: material.highlight.heightRatio）。
    static let highlightHeightRatio: CGFloat = 0.45

    /// 顶部高光不透明度。
    static let highlightOpacity: Double = 0.25
}
