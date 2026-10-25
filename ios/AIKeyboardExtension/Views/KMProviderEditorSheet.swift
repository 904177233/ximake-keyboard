//
//  KMProviderEditorSheet.swift
//  AIKeyboardExtension
//
//  模块职责：在**键盘内**完整编辑一个 AI 服务商（名称 / 地址 / 模型 / API Key），
//            并提供「测试连接」按钮。
//
//  ## 为什么这个界面必须存在（v2.0 的关键修复）
//  免费 Apple ID 签名无法配置 App Group，`SharedStore` 降级为
//  `UserDefaults.standard`，而 App 与键盘扩展是**两个独立进程、两个独立沙盒**。
//  因此「在宿主 App 里配好，键盘自动生效」这条路在免费签名下**物理上不存在**。
//
//  v1 的键盘设置页只提供「选择服务商」，文案还写着「编辑请到『墨语』App」——
//  于是用户把 API 配好了，键盘里却永远显示「还没有配置 AI 服务」，一用 AI 就报错。
//  这是用户反馈「api 配置好也没有办法正常使用，提示错误」的真正原因。
//
//  ## 设计依据
//  design/06-界面重构规范v2.md：不用玻璃、不用渐变、不用 Capsule；
//  主色只出现在「主按钮」一个动作位；字级只用 15/13/12 三档。
//

import SwiftUI

/// 键盘内的服务商编辑弹层。
struct KMProviderEditorSheet: View {

    /// 键盘状态机（读写配置与 Key 都走 `KeyboardViewModel+Provider`）。
    @ObservedObject var model: KeyboardViewModel

    /// 正在编辑的服务商（编辑过程只改这份草稿）。
    @State private var draft: AIProviderConfig

    /// API Key 输入框内容。
    @State private var apiKeyInput: String

    /// 是否显示 Key 明文。
    @State private var showsAPIKey: Bool = false

    /// 是否已存在 Key（决定提示文案与「删除 Key」按钮）。
    @State private var hasStoredKey: Bool

    /// 是否正在测试连接。
    @State private var isTesting: Bool = false

    /// 测试结果文案（成功/失败共用）。
    @State private var testResult: String?

    /// 测试结果是否为失败（决定颜色）。
    @State private var testFailed: Bool = false

    /// 保存成功回调。
    var onSaved: (() -> Void)?

    /// 关闭回调。
    var onClose: () -> Void

    /// 用现有服务商初始化。
    /// - Parameters:
    ///   - model: 键盘状态机。
    ///   - provider: 要编辑的服务商。
    ///   - onSaved: 保存成功后的回调。
    ///   - onClose: 关闭回调。
    init(
        model: KeyboardViewModel,
        provider: AIProviderConfig,
        onSaved: (() -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self._draft = State(initialValue: provider)
        let existingKey = KeychainStore.shared.apiKey(for: provider.id) ?? ""
        self._apiKeyInput = State(initialValue: existingKey)
        self._hasStoredKey = State(initialValue: !existingKey.isEmpty)
        self.onSaved = onSaved
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            KMSheetHeader(
                title: draft.name.isEmpty ? "编辑 AI 服务" : draft.name,
                subtitle: "填完点右下「保存」",
                onClose: onClose
            )

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    basicsSection
                    modelSection
                    apiKeySection
                    testResultSection
                    footnoteSection
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.xxl)
            }

            saveBar
        }
        .background(Theme.keyboardBackground)
    }

    // MARK: - 基础信息

    /// 名称 + 接口地址。
    private var basicsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle("服务")

            fieldRow(title: "名称") {
                TextField("DeepSeek", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            fieldRow(title: "接口地址") {
                TextField("https://api.deepseek.com/v1", text: $draft.baseURL)
                    .textFieldStyle(.plain)
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            if !baseURLHint.isEmpty {
                Text(baseURLHint)
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 地址提示：常见错误是漏了 `/v1` 或多写了 `/chat/completions`。
    private var baseURLHint: String {
        let trimmed = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasSuffix("/chat/completions") {
            return "地址只需要填到 /v1，不用带 /chat/completions。"
        }
        if !trimmed.hasPrefix("http") {
            return "地址要以 http:// 或 https:// 开头。"
        }
        return ""
    }

    // MARK: - 模型

    /// 模型名 + 常用模型快捷选择。
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle("模型")

            fieldRow(title: "模型名") {
                TextField("deepseek-chat", text: $draft.model)
                    .textFieldStyle(.plain)
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            let known = PresetProviders.knownModels(forBaseURL: draft.baseURL)
            if known.isEmpty {
                Text("这个地址没有内置的常用模型，直接输入服务商文档里的模型名即可。")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(known, id: \.self) { name in
                            Button {
                                draft.model = name
                                KMHaptics.chip()
                            } label: {
                                Text(name)
                                    .font(Theme.fontChip)
                                    .foregroundColor(draft.model == name ? Theme.textPrimary : Theme.textSecondary)
                                    .padding(.horizontal, Theme.Spacing.lg)
                                    .padding(.vertical, Theme.Spacing.sm)
                                    .background(
                                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                            .fill(draft.model == name ? Theme.keyFunctionBackground : Theme.chipBackground)
                                    )
                            }
                            .buttonStyle(KMPressableStyle(scale: 0.96))
                            .accessibilityLabel(Text("模型 \(name)"))
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
    }

    // MARK: - API Key

    /// API Key 输入。
    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle("API Key")

            HStack(spacing: Theme.Spacing.sm) {
                Group {
                    if showsAPIKey {
                        TextField("sk-...", text: $apiKeyInput)
                    } else {
                        SecureField("sk-...", text: $apiKeyInput)
                    }
                }
                .textFieldStyle(.plain)
                .font(Theme.fontBody)
                .foregroundColor(Theme.textPrimary)
                .autocapitalization(.none)
                .disableAutocorrection(true)

                Button {
                    showsAPIKey.toggle()
                    KMHaptics.chip()
                } label: {
                    KMIconGlyph(
                        symbol: showsAPIKey ? "eye.slash" : "eye",
                        fallback: showsAPIKey ? "隐" : "显",
                        size: 16,
                        tint: Theme.textSecondary
                    )
                    .frame(width: Theme.Sizing.minTapTarget, height: Theme.Sizing.minTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(KMPressableStyle(scale: 0.96))
                .accessibilityLabel(Text(showsAPIKey ? "隐藏 API Key" : "显示 API Key"))
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: Theme.MaterialToken.strokeWidth)
            )

            HStack(spacing: Theme.Spacing.sm) {
                Text(hasStoredKey ? "已存在本机钥匙串" : "只存在本机钥匙串，不会上传")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textTertiary)

                Spacer(minLength: 0)

                if hasStoredKey {
                    Button {
                        apiKeyInput = ""
                        hasStoredKey = model.saveAPIKey("", forProviderID: draft.id)
                        KMHaptics.warning()
                    } label: {
                        Text("删除 Key")
                            .font(Theme.fontCaption)
                            .foregroundColor(Theme.danger)
                    }
                    .buttonStyle(KMPressableStyle(scale: 0.96))
                    .accessibilityLabel(Text("删除 API Key"))
                }
            }
        }
    }

    // MARK: - 测试结果

    /// 测试结果条。
    @ViewBuilder
    private var testResultSection: some View {
        if let testResult {
            Text(testResult)
                .font(Theme.fontCaption)
                .foregroundColor(testFailed ? Theme.danger : Theme.success)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 说明块：为什么这里要再填一次。
    private var footnoteSection: some View {
        Text("为什么这里要再填一遍？\n免费签名做不了 App Group，键盘和 App 是两个互不相通的沙盒，App 里填的 Key 键盘读不到。这是苹果的限制，不是 bug。买了 99 美元/年的开发者账号并开启 App Group 之后，两边会自动同步。")
            .font(Theme.fontCaption)
            .foregroundColor(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 保存栏

    /// 底部：测试连接 + 保存。
    private var saveBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            KMSecondaryButton(
                title: isTesting ? "测试中…" : "测试连接",
                systemImage: "bolt.horizontal",
                isEnabled: !isTesting && canTest
            ) {
                testConnection()
            }

            KMPrimaryButton(
                title: "保存",
                systemImage: "checkmark",
                isEnabled: canSave
            ) {
                save()
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.candidateBar)
        .overlay(alignment: .top) {
            Theme.candidateSeparator.frame(height: Theme.MaterialToken.strokeWidth)
        }
    }

    // MARK: - 校验

    /// 能否测试：地址 + 模型 + Key 都有值。
    private var canTest: Bool {
        !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 能否保存：名称 + 地址 + 模型 + Key 都有值（或已有 Key）。
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasStoredKey)
    }

    // MARK: - 动作

    /// 保存整套配置。
    private func save() {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)

        var updated = draft
        updated.name = trimmedName.isEmpty ? "AI 服务" : trimmedName
        updated.baseURL = trimmedURL
        updated.model = trimmedModel

        // 先存 Key 再存配置：Key 存失败时不应该留下一个「指向不存在的 Key」的服务商。
        hasStoredKey = model.saveAPIKey(apiKeyInput, forProviderID: updated.id)
        model.saveProvider(updated)
        KMHaptics.success()
        onSaved?()
    }

    /// 测试连接：走 `KeyboardViewModel.probeProvider`（扩展 target 自己的探活实现）。
    private func testConnection() {
        guard canTest else { return }
        isTesting = true
        testResult = nil
        testFailed = false

        let config = draft
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)

        Task { @MainActor in
            let outcome = await model.probeProvider(config: config, apiKey: key)
            testFailed = outcome.failed
            testResult = outcome.message
            isTesting = false
        }
    }

    // MARK: - 小组件

    /// 小节标题。
    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.fontChip)
            .foregroundColor(Theme.textSecondary)
    }

    /// 一行「标题 + 输入框」。
    private func fieldRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(title)
                .font(Theme.fontBody)
                .foregroundColor(Theme.textPrimary)
                .frame(width: 64, alignment: .leading)

            content()
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: Theme.MaterialToken.strokeWidth)
                )
        }
    }
}
