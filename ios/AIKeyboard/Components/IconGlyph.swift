//
//  IconGlyph.swift
//  墨语 · 宿主 App 组件
//
//  L1 原子组件：SF Symbol 与 emoji 的统一入口（契约 §2.3）。
//  解决「SF Symbol 在当前系统不可用时变空白」的问题：不可用则渲染 fallback 文字/emoji。
//
import SwiftUI

/// 图标渲染器：SF Symbol 优先，不可用时降级为文字/emoji。
struct IconGlyph: View {

    /// SF Symbol 名。
    let symbol: String

    /// 不可用时的降级文字（通常是 emoji）。
    var fallback: String

    /// 字号。
    var size: CGFloat

    /// 字重。
    var weight: Font.Weight

    /// 颜色（nil 表示继承前景色）。
    var tint: Color?

    init(
        symbol: String,
        fallback: String = "",
        size: CGFloat = AppMetrics.glyphSize,
        weight: Font.Weight = .regular,
        tint: Color? = nil
    ) {
        self.symbol = symbol
        self.fallback = fallback
        self.size = size
        self.weight = weight
        self.tint = tint
    }

    var body: some View {
        Group {
            if Self.isSymbolAvailable(symbol) {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
            } else {
                Text(fallback.isEmpty ? symbol : fallback)
                    .font(.system(size: size, weight: weight))
            }
        }
        .foregroundColor(tint)
        .accessibilityHidden(true)
    }

    /// 判断某个 SF Symbol 在当前系统是否可用（系统缓存，避免每次 body 都查表）。
    static func isSymbolAvailable(_ name: String) -> Bool {
        symbolCache[name] ?? resolve(name)
    }

    // MARK: - 缓存

    private static var symbolCache: [String: Bool] = [:]

    private static func resolve(_ name: String) -> Bool {
        let available = UIImage(systemName: name) != nil
        symbolCache[name] = available
        return available
    }
}

/// AI 能力图标映射（契约 §2.3：全局唯一，UI 两侧共用）。
enum FeatureGlyph {

    /// SF Symbol 名。
    static func symbol(for feature: AIFeature) -> String {
        switch feature {
        case .polish:
            return "sparkles"
        case .expand:
            return "text.append"
        case .translate:
            return "globe"
        case .replySuggestion:
            return "bubble.left.and.bubble.right"
        case .image:
            return "photo.on.rectangle.angled"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    /// 降级 emoji。
    static func fallback(for feature: AIFeature) -> String {
        switch feature {
        case .polish:
            return "✨"
        case .expand:
            return "💬"
        case .translate:
            return "🌐"
        case .replySuggestion:
            return "🧠"
        case .image:
            return "🎨"
        case .custom:
            return "⚙️"
        }
    }
}

#if DEBUG
struct IconGlyph_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: AppMetrics.blockGap) {
            ForEach(AIFeature.allCases, id: \.self) { feature in
                IconGlyph(
                    symbol: FeatureGlyph.symbol(for: feature),
                    fallback: FeatureGlyph.fallback(for: feature),
                    size: AppMetrics.mediumIcon,
                    tint: Theme.accent
                )
            }
        }
        .padding(AppMetrics.pageInset)
        .background(AppColor.pageBackground)
    }
}
#endif
