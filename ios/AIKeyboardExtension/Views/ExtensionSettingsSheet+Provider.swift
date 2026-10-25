//
//  ExtensionSettingsSheet+Provider.swift
//  AIKeyboardExtension
//
//  模块职责：键盘设置页的「AI 服务商」弹层（列表 / 编辑入口 / 新增）。
//
//  从 `ExtensionSettingsSheet.swift` 拆出来的原因：那个文件已到 589 行、
//  贴住 600 行硬上限，再往里加东西必然触发 `[P2] FILE-TOO-LONG`。
//  拆分边界选在「服务商弹层」这个完整功能块，不动其余七个设置行。
//
//  ## 这一页为什么是 v2.0 的关键
//  免费签名没有 App Group，宿主 App 里配的服务商与 API Key **键盘读不到**。
//  旧版这一页只让「选」不让「改」，于是用户配好 API 后键盘永远显示
//  「还没有配置 AI 服务」，一用 AI 就报错 —— 这是用户反馈
//  「api 配置好也没有办法正常使用」的真正原因。现在这一页可以：
//  ①新增服务 ②编辑地址/模型 ③填 API Key ④测试连通。
//

import SwiftUI

extension ExtensionSettingsSheet {

    /// AI 服务商列表（可编辑 / 可新增）。
    var providerPicker: some View {
        VStack(spacing: 0) {
            KMSheetHeader(title: "AI 服务商", subtitle: "点一行即可编辑地址与 API Key", onClose: { activeSheet = nil })

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.snapshot.providers) { provider in
                        HStack(spacing: Theme.Spacing.md) {
                            // 点主体 → 编辑（地址 / 模型 / Key）。
                            // 这是 v2.0 的关键修复：键盘与 App 无 App Group，Key 必须在本页自己填。
                            Button(action: {
                                KMHaptics.chip()
                                editingProvider = provider
                                activeSheet = nil
                            }) {
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: Theme.Spacing.sm) {
                                        Text(provider.name)
                                            .font(Theme.fontBody)
                                            .foregroundColor(Theme.textPrimary)
                                        if model.hasAPIKey(forProviderID: provider.id) {
                                            Text("已填 Key")
                                                .font(Theme.fontCaption)
                                                .foregroundColor(Theme.success)
                                        } else {
                                            Text("缺 Key")
                                                .font(Theme.fontCaption)
                                                .foregroundColor(Theme.warning)
                                        }
                                    }
                                    Text(provider.displaySummary)
                                        .font(Theme.fontCaption)
                                        .foregroundColor(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: KMLayout.settingsRowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(KMPressableStyle(scale: 0.99))
                            .accessibilityLabel(Text("编辑服务商 \(provider.name)"))

                            // 右侧：设为默认。
                            Button(action: {
                                KMHaptics.chip()
                                model.setDefaultProvider(provider.id)
                            }) {
                                KMIconGlyph(
                                    symbol: model.snapshot.defaultProviderID == provider.id ? "checkmark.circle.fill" : "circle",
                                    fallback: model.snapshot.defaultProviderID == provider.id ? "●" : "○",
                                    size: 20,
                                    tint: model.snapshot.defaultProviderID == provider.id ? Theme.accent : Theme.textTertiary
                                )
                                .frame(width: Theme.Sizing.minTapTarget, height: Theme.Sizing.minTapTarget)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(KMPressableStyle(scale: 0.96))
                            .accessibilityLabel(Text("把 \(provider.name) 设为默认"))
                        }
                        .padding(.horizontal, Theme.Spacing.xl)
                    }

                    if model.snapshot.providers.isEmpty {
                        KMEmptyState(
                            systemImage: "exclamationmark.triangle",
                            fallback: "!",
                            title: "还没有配置 AI 服务",
                            message: "点下面的「新增服务」填地址与 API Key"
                        )
                    }

                    // 新增入口：免费签名下这是唯一能配 AI 的地方。
                    Button(action: {
                        KMHaptics.chip()
                        let newID = model.addProviderFromPreset()
                        editingProvider = model.snapshot.providers.first(where: { $0.id == newID })
                        activeSheet = nil
                    }) {
                        HStack(spacing: Theme.Spacing.sm) {
                            KMIconGlyph(symbol: "plus", fallback: "+", size: 16, tint: Theme.accent)
                            Text("新增服务")
                                .font(Theme.fontBody)
                                .foregroundColor(Theme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: KMLayout.settingsRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(KMPressableStyle(scale: 0.99))
                    .accessibilityLabel(Text("新增 AI 服务"))
                }
            }
        }
        .padding(.bottom, Theme.Spacing.xl)
        .presentationDetents([.medium])
    }
}
