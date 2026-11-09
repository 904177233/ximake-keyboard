//
//  ScrollEdgeBlur.swift
//  墨语 · 键盘
//
//  iOS 26 起，滚动视图会在边上自动加一层模糊（scroll edge effect）。
//  键盘的候选栏、工具栏和面板都很窄，模糊会盖住大半内容（模拟器截图里候选和工具图标都是糊的），
//  所以键盘里的滚动视图一律关掉。
//

import SwiftUI
import UIKit

extension UIScrollView {
    /// 关掉 iOS 26 的边缘模糊。
    func hideEdgeBlur() {
        if #available(iOS 26.0, *) {
            topEdgeEffect.isHidden = true
            bottomEdgeEffect.isHidden = true
            leftEdgeEffect.isHidden = true
            rightEdgeEffect.isHidden = true
        }
    }
}

extension View {
    /// 关掉 iOS 26 的边缘模糊。
    @ViewBuilder
    func hideEdgeBlur() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}
