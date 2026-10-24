//
//  KeyboardViewModel+Panel.swift
//  墨语（Moyu）键盘扩展 · AI 面板文本编辑
//
//  模块职责：实现 AI 面板输入框的「焦点重定向自绘输入」——扩展内无法可靠唤起系统键盘，
//            因此面板编辑态由键盘自己的按键把字符写进本缓冲，光标位置也由本类型维护
//            （`panelCursor` 以 `Character` 计），最终随「生成」一起发给模型。
//  设计依据：docs/02 §4.7、design/键盘布局规范.md §4.4（面板 168 高度与输入框规格）、§9。
//  降级路径：若产品要求 P0 只读上下文，把 `isPanelEditing` 固定为 false 即可，
//            面板退化为「只读上下文 + 点 chip 直接生成」，其余代码不受影响。
//

import Foundation
import UIKit

extension KeyboardViewModel {

    // MARK: - 文本与光标

    /// 覆盖面板文本（同时把光标移到末尾）。
    /// - Parameter text: 新文本。
    public func setPanelText(_ text: String) {
        panelText = text
        panelCursor = min(max(panelCursor, 0), text.count)
        if panelCursor == 0 { panelCursor = text.count }
    }

    /// 切换面板编辑态。
    /// - Parameter editing: 是否可编辑。
    public func setPanelEditing(_ editing: Bool) {
        isPanelEditing = editing
        if editing {
            panelCursor = min(max(panelCursor, 0), panelText.count)
        }
    }

    /// 一键填入当前宿主输入框内容（取末尾 200 字）。
    public func fillPanelFromHost() {
        let context = contextTail
        guard !context.isEmpty else {
            showToast("当前输入框没有内容")
            return
        }
        panelText = context
        panelCursor = context.count
        panelContextPreview = context
        showsContextTruncationHint = proxyContext.count > Self.contextCharacterLimit
        showToast("已填入当前输入内容")
    }

    /// 一键从系统剪贴板填入（无完全访问时读取会失败，给出文字提示）。
    public func fillPanelFromClipboard() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasStrings, let text = pasteboard.string, !text.isEmpty else {
            showToast("读不到剪贴板；开启完全访问后可用")
            return
        }
        let clipped = Self.tail(of: text, limit: Self.contextCharacterLimit)
        panelText = clipped
        panelCursor = clipped.count
        panelContextPreview = clipped
        showsContextTruncationHint = text.count > Self.contextCharacterLimit
        showToast("已从剪贴板填入")
    }

    // MARK: - 编辑操作（由 `tap(_:)` 在编辑态转发）

    /// 在光标处插入文本。
    /// - Parameter text: 待插入文本。
    public func panelInsert(_ text: String) {
        guard !text.isEmpty else { return }
        let index = panelText.index(panelText.startIndex, offsetBy: clampCursor(panelCursor))
        panelText.insert(contentsOf: text, at: index)
        panelCursor += text.count
    }

    /// 删除光标前一个字符。
    public func panelBackspace() {
        guard panelCursor > 0, !panelText.isEmpty else { return }
        let index = panelText.index(panelText.startIndex, offsetBy: clampCursor(panelCursor - 1))
        panelText.remove(at: index)
        panelCursor = max(panelCursor - 1, 0)
    }

    /// 光标左移一位。
    public func panelMoveCursorLeft() {
        panelCursor = max(panelCursor - 1, 0)
    }

    /// 光标右移一位。
    public func panelMoveCursorRight() {
        panelCursor = min(panelCursor + 1, panelText.count)
    }

    /// 清空面板文本。
    public func panelClear() {
        panelText = ""
        panelCursor = 0
    }

    /// 语气切换（写回配置，下次打开键盘仍生效）。
    /// - Parameter tone: 语气文案（自然 / 简洁 / 礼貌 / 正式 / 热情）。
    public func setTone(_ tone: String) {
        self.tone = tone
        var updated = snapshot
        updated.defaultTone = tone
        snapshot = updated
        configStore.save(updated)
        SharedStore.shared.set(tone, forKey: SharedStoreKey.currentTone)
    }

    /// 面板「发送」：把当前面板文本作为一次 AI 请求的输入。
    /// - Parameter feature: 目标能力（默认润色）。
    public func submitPanel(feature: AIFeature? = nil) {
        let target = feature ?? lastFeature
        let text = panelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showToast("请先输入要处理的内容")
            return
        }
        lastRequestText = text
        startAI(target)
    }

    // MARK: - 数据刷新

    /// 重新读取配置快照（设置里改完 Provider / 语气后调用）。
    public func reloadSnapshot() {
        snapshot = configStore.load()
        tone = snapshot.defaultTone
        refreshAvailability()
        refreshPhrases()
        refreshClipboard()
    }

    /// 切换剪贴板历史开关（键盘内设置页可切）。
    /// - Parameter enabled: 是否启用。
    public func setClipboardHistoryEnabled(_ enabled: Bool) {
        var updated = snapshot
        updated.enableClipboardHistory = enabled
        snapshot = updated
        configStore.save(updated)
        engine.setClipboardEnabled(enabled)
        refreshClipboard()
    }

    /// 切换「AI 联想词」开关（键盘内设置页可切，宿主 App 同键同义）。
    ///
    /// 关闭后 `KeyboardViewModel+Suggest` 的 `scheduleSuggestions()` 会直接清空并
    /// **不创建任何 Task**（不做请求、不占额度、不刷候选栏）。
    /// - Parameter enabled: 是否启用。
    public func setAISuggestionEnabled(_ enabled: Bool) {
        var updated = snapshot
        updated.enableAISuggestion = enabled
        snapshot = updated
        configStore.save(updated)
        if !enabled { clearSuggestions() }
    }

    /// 切换「输入纠错」开关（键盘内设置页可切，宿主 App 同键同义）。
    ///
    /// 纠错本身在 `PinyinEngine+TypoCorrection` 层按默认启用并打 `[纠错]` 角标；
    /// 关闭后由视图层过滤掉 `isTypoCorrection == true` 的候选（见 `CandidateBar`）。
    /// - Parameter enabled: 是否启用。
    public func setTypoCorrectionEnabled(_ enabled: Bool) {
        var updated = snapshot
        updated.enableTypoCorrection = enabled
        snapshot = updated
        configStore.save(updated)
    }

    /// 切换默认服务商（键盘内设置页只做切换，完整编辑在宿主 App）。
    /// - Parameter providerID: 服务商 ID。
    public func setDefaultProvider(_ providerID: String?) {
        var updated = snapshot
        updated.defaultProviderID = providerID
        snapshot = updated
        configStore.save(updated)
        refreshAvailability()
    }

    /// 从宿主导出的配置里导入（`PasteboardBridge` 已实现信封校验）。
    /// - Returns: 是否导入成功。
    @discardableResult
    public func importConfigFromPasteboard() -> Bool {
        guard let imported = PasteboardBridge.importSnapshot() else {
            showToast("剪贴板里没有可导入的配置")
            return false
        }
        configStore.save(imported)
        snapshot = imported
        tone = imported.defaultTone
        engine.setClipboardEnabled(imported.enableClipboardHistory)
        refreshPhrases()
        refreshClipboard()
        refreshAvailability()
        showToast("配置已导入")
        return true
    }

    /// 把当前配置写到剪贴板，供宿主 App 或另一台设备导入。
    public func exportConfigToPasteboard() {
        do {
            try PasteboardBridge.export(snapshot, includeAPIKeys: false)
            showToast("配置已复制，可粘贴到宿主 App 导入")
        } catch {
            showToast("导出失败，请稍后重试")
        }
    }

    // MARK: - 私有工具

    /// 把光标偏移夹在合法区间内。
    /// - Parameter value: 原始偏移。
    /// - Returns: 合法偏移。
    private func clampCursor(_ value: Int) -> Int {
        min(max(value, 0), panelText.count)
    }
}
