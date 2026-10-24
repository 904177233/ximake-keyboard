//
//  ViewCompat.swift
//  墨语 · 宿主 App
//
//  模块职责：iOS 16 兼容的 SwiftUI 修饰符集中放置处。
//            避免在多个页面文件里重复声明同名扩展（会触发 invalid redeclaration）。
//  依赖：SwiftUI。
//  使用方：PlaygroundView、PromptEditorView 等需要隐藏 TextEditor 背景的页面。
//

import SwiftUI

extension View {

    /// 隐藏 `TextEditor` / `List` 的默认滚动背景（iOS 16 起支持）。
    /// 工程下限是 iOS 16，这里仍保留可用性判断，方便以后降级到 iOS 15 预览。
    @ViewBuilder
    func scrollContentBackgroundHiddenCompat() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
