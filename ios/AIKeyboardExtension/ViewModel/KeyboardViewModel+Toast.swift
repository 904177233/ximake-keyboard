//
//  KeyboardViewModel+Toast.swift
//  AIKeyboardExtension
//
//  模块职责：键盘内的轻量 Toast（从 `KeyboardViewModel.swift` 抽出来，
//            让主文件回到 600 行以内）。
//  依赖：Foundation、KeyboardViewModel。
//  使用方：任何需要「一句话提示」的交互（复制成功、剪贴板里没有配置等）。
//

import Foundation

extension KeyboardViewModel {

    /// 展示一次 Toast 提示（自动消失）。
    ///
    /// 用「文案相等」判断是否仍是最新一条：连续弹两条不同文案时，
    /// 前一条的定时器醒来发现当前文案已被替换，就不会误清空后一条。
    /// - Parameter message: 中文提示文案。
    public func showToast(_ message: String) {
        toastMessage = message
        let expected = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            if self.toastMessage == expected {
                self.toastMessage = nil
            }
        }
    }

    /// 关闭 Toast。
    public func clearToast() {
        toastMessage = nil
    }
}
