//
//  KMSolidSurface.swift
//  墨语（Moyu）键盘扩展 · 实色卡片
//
//  模块职责：键盘内的「卡片」容器。**只用一个实色 + 一条 0.5pt 发丝描边**，
//            不叠材质、不加高光、不加渐变、不加投影。
//  设计依据：design/06-界面重构规范v2.md §1.6「材质策略」、§1.8「禁止项清单」。
//
//  为什么替代 KMGlassSurface：
//  键盘是「一块浅灰板 + 一堆白片」，玻璃材质（`.ultraThinMaterial`）在这里
//  会把它变成第二种实体，反而让键区看起来像被一层雾盖住；而且键盘背景是纯色，
//  毛玻璃后面没有可透的东西，模糊出来的效果等于「描边变脏 + 底色发灰」。
//  真正需要分层的只有 AI 面板 / 结果卡，那些位置用一条发丝线加实色底就够。
//

import SwiftUI

/// 键盘内的实色卡片容器。
struct KMSolidSurface<Content: View>: View {

    /// 圆角（默认卡片圆角 16）。
    var cornerRadius: CGFloat = Theme.Radius.card

    /// 是否画底部发丝分隔线。
    var showsBottomRule: Bool = false

    /// 内容。
    @ViewBuilder let content: () -> Content

    var body: some View {
        content
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                // 唯一允许的分层手法：0.5pt 发丝描边（design/06 §1.6）。
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: Theme.MaterialToken.strokeWidth)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if showsBottomRule {
                    Theme.separator
                        .frame(height: Theme.MaterialToken.strokeWidth)
                        .allowsHitTesting(false)
                }
            }
    }
}
