//
//  ExtensionSettingsSheet.swift
//  墨语（Moyu）键盘扩展 · 键盘内设置页
//
//  模块职责：复用 168 的高度增量，做一个列表式设置页（头部 52 + 5 行 × 44，内部可滚动，高度恒定）。
//            行：①默认 AI 服务商（只做切换）②默认语气（只做切换）③快捷短语（入口提示）
//            ④剪贴板历史（开关，只读说明）⑤配置同步（导入 / 导出到剪贴板）。
//            完整编辑（增删服务商、填 API Key、连通性测试）在宿主 App 完成 —— 见 README「已知限制」。
//  设计依据：design/键盘布局规范.md §4.6、PRD §4.1（键盘内设置 Sheet）。
//  约束：扩展内不得跳转系统设置（不能用 openURL / UIApplication），需要开完全访问时只能文字提示。
//

import SwiftUI

/// 键盘内设置页。
struct ExtensionSettingsSheet: View {

    /// 键盘状态机。
    @ObservedObject var model: KeyboardViewModel

    /// 设置操作弹层（Provider 选择 / 语气选择 / 配置同步）。
    @State private var activeSheet: ActiveSheet?

    var body: some View {
        VStack(spacing: 0) {
            KMSheetHeader(
                title: "键盘设置",
                subtitle: "完整编辑请到「墨语」App",
                showsClose: true,
                onClose: { model.tap(.closeSettings) }
            )

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    providerRow
                    divider
                    toneRow
                    divider
                    phraseRow
                    divider
                    clipboardRow
                    divider
                    fuzzyRow
                    divider
                    syncRow
                    divider
                    dictionaryRow
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: KMLayout.aiPanelExtraHeight)
        .background(Theme.keyboardBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: Theme.MaterialToken.strokeWidth)
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 行

    /// ①默认 AI 服务商。
    private var providerRow: some View {
        SettingsRowButton(
            emoji: "🌐",
            title: "AI 服务商",
            detail: model.snapshot.defaultProvider?.name ?? "未配置",
            showsDisclosure: true,
            action: { activeSheet = .provider }
        )
        .accessibilityLabel(Text("AI 服务商，当前 \(model.snapshot.defaultProvider?.name ?? "未配置")"))
    }

    /// ②默认语气。
    private var toneRow: some View {
        SettingsRowButton(
            emoji: "🎚",
            title: "默认语气",
            detail: model.tone,
            showsDisclosure: true,
            action: { activeSheet = .tone }
        )
        .accessibilityLabel(Text("默认语气，当前 \(model.tone)"))
    }

    /// ③快捷短语（键盘内只读入口）。
    private var phraseRow: some View {
        SettingsRowButton(
            emoji: "🗂",
            title: "快捷短语",
            detail: "\(model.phrases.count) 条",
            showsDisclosure: true,
            action: {
                model.tap(.closeSettings)
                model.tap(.openPhraseBar)
            }
        )
        .accessibilityLabel(Text("快捷短语，共 \(model.phrases.count) 条"))
    }

    /// ④剪贴板历史（开关 + 只读说明）。
    private var clipboardRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("📋")
                .font(Theme.fontBody)
            VStack(alignment: .leading, spacing: 0) {
                Text("剪贴板历史")
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                Text(model.hasFullAccess ? "最多保留 20 条" : "需要完全访问才能读取剪贴板")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { model.snapshot.enableClipboardHistory },
                set: { value in model.setClipboardHistoryEnabled(value) }
            ))
            .labelsHidden()
            .tint(Theme.accent)
            .accessibilityLabel(Text("剪贴板历史开关"))
        }
        .frame(height: KMLayout.settingsRowHeight)
        .padding(.horizontal, Theme.Spacing.xl)
    }

    /// ⑤模糊音（开关）：`zh/z`、`ch/c`、`sh/s`、`in/ing`、`l/n` 不分也能打出来。
    ///
    /// 默认开启（内核默认规则 5 条）；状态来自 `KeyboardViewModel.fuzzyPinyinEnabled`，
    /// 切换后经 `IMEKit` → `PinyinEngine` 立即生效并持久化到 `moyu.ime.fuzzy.v1`。
    private var fuzzyRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("〰️")
                .font(Theme.fontBody)
            VStack(alignment: .leading, spacing: 0) {
                Text("模糊音")
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                Text("zh/z、ch/c、sh/s、in/ing、l/n 不分也能打出来")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { model.fuzzyPinyinEnabled },
                set: { value in model.setFuzzyPinyinEnabled(value) }
            ))
            .labelsHidden()
            .tint(Theme.accent)
            .accessibilityLabel(Text("模糊音开关"))
        }
        .frame(height: KMLayout.settingsRowHeight)
        .padding(.horizontal, Theme.Spacing.xl)
    }

    /// ⑥配置导入 / 导出。
    private var syncRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("⇅")
                .font(Theme.fontBody)
            VStack(alignment: .leading, spacing: 0) {
                Text("同步配置")
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                Text("通过剪贴板在 App 与键盘之间同步")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: {
                KMHaptics.chip()
                model.exportConfigToPasteboard()
            }) {
                Text("导出")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.accent)
                    .frame(minWidth: Theme.Sizing.minTapTarget, minHeight: Theme.Sizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.96))
            .accessibilityLabel(Text("导出配置到剪贴板"))

            Button(action: {
                KMHaptics.chip()
                _ = model.importConfigFromPasteboard()
            }) {
                Text("导入")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.accent)
                    .frame(minWidth: Theme.Sizing.minTapTarget, minHeight: Theme.Sizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.96))
            .accessibilityLabel(Text("从剪贴板导入配置"))
        }
        .frame(height: KMLayout.settingsRowHeight)
        .padding(.horizontal, Theme.Spacing.xl)
    }

    /// ⑦词库来源（诊断行：排查"候选中没有中文"的第一现场证据）。
    ///
    /// 取值来自 `IMEKit.diagnosticsSummary`（`model.dictionarySummary`）。
    /// 正常态用小字 `Theme.textSecondary`；命中「内置兜底词库」时改 `Theme.warning` 并前置 ⚠️。
    /// 本行只是增加一条可滚动行，不改变设置页高度（高度恒为 `KMLayout.aiPanelExtraHeight`）。
    private var dictionaryRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("词库来源")
                .font(Theme.fontBody)
                .foregroundColor(Theme.textPrimary)
            Text(dictionarySummaryText)
                .font(Theme.fontCaption)
                .foregroundColor(isFallbackDictionary ? Theme.warning : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: KMLayout.settingsRowHeight)
        .padding(.horizontal, Theme.Spacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("词库来源，\(dictionarySummaryText)"))
    }

    /// 词库摘要文案：兜底词库时前置警示符号；尚未加载时给占位文案。
    private var dictionarySummaryText: String {
        let summary = model.dictionarySummary
        if summary.isEmpty {
            return "正在读取词库…"
        }
        if isFallbackDictionary {
            return "⚠️ " + summary
        }
        return summary
    }

    /// 是否处于「内置兜底词库」异常态（打包词库没读到时 `IMEKit` 会退回 50 条极小词表）。
    private var isFallbackDictionary: Bool {
        let summary = model.dictionarySummary
        return summary.contains("兜底") || summary.contains("内置")
    }

    /// 行分隔线（0.5pt）。
    private var divider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: Theme.MaterialToken.strokeWidth)
            .padding(.leading, Theme.Spacing.xl)
    }

    // MARK: - 弹层

    /// 当前弹层类型。
    private enum ActiveSheet: String, Identifiable {
        /// 服务商选择。
        case provider
        /// 语气选择。
        case tone
        /// 配置同步说明。
        case sync

        var id: String { rawValue }
    }

    /// 弹层内容。
    /// - Parameter sheet: 弹层类型。
    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .provider:
            providerPicker
        case .tone:
            tonePicker
        case .sync:
            syncPicker
        }
    }

    /// 服务商选择（只切换默认，不编辑）。
    private var providerPicker: some View {
        VStack(spacing: 0) {
            KMSheetHeader(title: "选择 AI 服务商", subtitle: "编辑请到「墨语」App", onClose: { activeSheet = nil })

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.snapshot.providers) { provider in
                        Button(action: {
                            KMHaptics.chip()
                            model.setDefaultProvider(provider.id)
                            activeSheet = nil
                        }) {
                            HStack(spacing: Theme.Spacing.md) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(provider.name)
                                        .font(Theme.fontBody)
                                        .foregroundColor(Theme.textPrimary)
                                    Text(provider.displaySummary)
                                        .font(Theme.fontCaption)
                                        .foregroundColor(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if model.snapshot.defaultProviderID == provider.id {
                                    KMIconGlyph(symbol: "checkmark", fallback: "✓", size: 14, tint: Theme.accent)
                                }
                            }
                            .frame(minHeight: KMLayout.settingsRowHeight)
                            .padding(.horizontal, Theme.Spacing.xl)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(KMPressableStyle(scale: 0.99))
                        .accessibilityLabel(Text("服务商 \(provider.name)"))
                    }

                    if model.snapshot.providers.isEmpty {
                        KMEmptyState(
                            systemImage: "exclamationmark.triangle",
                            fallback: "!",
                            title: "还没有配置 AI 服务",
                            message: "打开「墨语」App，在 AI 服务里添加一个服务商"
                        )
                    }
                }
            }
        }
        .padding(.bottom, Theme.Spacing.xl)
        .presentationDetents([.medium])
    }

    /// 语气选择。
    private var tonePicker: some View {
        VStack(spacing: 0) {
            KMSheetHeader(title: "选择默认语气", onClose: { activeSheet = nil })

            KMToneSelector(selected: model.tone, onSelect: { tone in
                model.setTone(tone)
                activeSheet = nil
            })
            .padding(.vertical, Theme.Spacing.md)
        }
        .presentationDetents([.height(Theme.Sizing.candidateBarHeight + Theme.Sizing.aiPanelToneRowHeight + Theme.Spacing.xxl)])
    }

    /// 配置同步说明。
    private var syncPicker: some View {
        VStack(spacing: Theme.Spacing.lg) {
            KMSheetHeader(title: "同步配置", onClose: { activeSheet = nil })
            Text("导出：把当前服务商、语气、短语配置写入剪贴板；\n导入：从剪贴板读取并覆盖本机配置。\nAPI Key 不会随配置一起导出。")
                .font(Theme.fontBody)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.xl)
            Spacer(minLength: 0)
        }
        .presentationDetents([.height(Theme.Sizing.letterRowHeight * 3 + Theme.Sizing.keyHeight * 2)])
    }
}

// MARK: - 设置行

/// 设置行（emoji + 标题 + 右侧详情 + 箭头），命中区 ≥44。
struct SettingsRowButton: View {

    /// 前置 emoji。
    let emoji: String

    /// 标题。
    let title: String

    /// 右侧详情。
    let detail: String

    /// 是否显示右侧箭头。
    var showsDisclosure: Bool = true

    /// 点击回调。
    let action: () -> Void

    var body: some View {
        Button(action: {
            KMHaptics.chip()
            action()
        }) {
            HStack(spacing: Theme.Spacing.md) {
                Text(emoji)
                    .font(Theme.fontBody)
                    .frame(width: Theme.Spacing.xxl)
                Text(title)
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
                Text(detail)
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                if showsDisclosure {
                    KMIconGlyph(symbol: "chevron.right", fallback: "›", size: 11, tint: Theme.textTertiary)
                }
            }
            .frame(height: KMLayout.settingsRowHeight)
            .padding(.horizontal, Theme.Spacing.xl)
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.99, pressedOpacity: 0.9))
        .accessibilityLabel(Text("\(title)，\(detail)"))
        .accessibilityAddTraits(.isButton)
    }
}
