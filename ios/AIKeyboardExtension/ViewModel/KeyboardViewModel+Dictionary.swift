import Foundation

/// 在线词库包：键盘扩展侧的自动检查与热重载。
///
/// 为什么单独一个文件：`KeyboardViewModel.swift` 已经贴在 600 行硬上限上
/// （`scripts/qa/static_check.py` 的 `FILE-TOO-LONG` 会报 P2），而这段逻辑
/// 与「打字」本身无关，只是「启动后顺手问一句有没有新词库」。
extension KeyboardViewModel {

    /// 启动在线词库包自动检查。
    ///
    /// 三个必须点：
    /// 1. **不 `await`**：它要发网络请求，绝不能挡住首帧渲染 ——
    ///    键盘扩展最硬的指标是「快得让用户无感」。
    /// 2. **失败完全静默**：词库更新失败不该让用户看到任何东西，它不影响打字。
    /// 3. **有 24 小时节流**（`DictionaryPackStore.autoCheckIfNeeded` 内部判断），
    ///    所以每次唤起键盘调用它是安全的。
    ///
    /// 只有开了「允许完全访问」扩展才有网络权限；未开时第一次请求就会失败并记下时间，
    /// 24 小时内不再重试，不会反复骚扰网络栈。
    func scheduleDictionaryPackCheck() {
        Task { [weak self] in
            let didCheck = await DictionaryPackStore.shared.autoCheckIfNeeded()
            guard didCheck else { return }
            // 词库换过之后必须重建内核，否则内存里还是旧词表。
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.engine.reload()
                self.dictionarySummary = self.engine.diagnosticsSummary
            }
        }
    }
}
