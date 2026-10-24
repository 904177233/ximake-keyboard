//
//  KMIconGlyph.swift
//  墨语（Moyu）键盘扩展 · SF Symbol 图标
//
//  模块职责：把「系统符号名 + 文字兜底」渲染成图标，符号缺失时退回字符，
//            避免键盘里出现空白按钮（不同 iOS 版本符号可用性不一致）。
//  设计依据：design/组件库.md「IconGlyph：用 `UIImage(systemName:) != nil` 判可用性」。
//

import SwiftUI
import UIKit

/// 图标字形。
struct KMIconGlyph: View {

    /// 首选 SF Symbol 名。
    let symbol: String

    /// 符号不可用时的文字兜底（通常是 emoji 或单字符）。
    let fallback: String

    /// 图标字号（token: typography.headline.size = 17）。
    var size: CGFloat = 17

    /// 字重。
    var weight: Font.Weight = .regular

    /// 颜色。
    var tint: Color = Theme.textPrimary

    var body: some View {
        Group {
            if UIImage(systemName: symbol) != nil {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundColor(tint)
            } else {
                Text(fallback)
                    .font(.system(size: size, weight: weight))
                    .foregroundColor(tint)
            }
        }
        .accessibilityHidden(true)
    }
}
