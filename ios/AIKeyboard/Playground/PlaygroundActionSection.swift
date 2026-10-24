//
//  PlaygroundActionSection.swift
//  墨语 · 宿主 App
//
//  模块职责：「AI 试验场」的生成按钮、结果卡、提示卡与全部业务逻辑
//            （发起请求 / 复制 / 保存为短语 / 同步默认值）。
//            作为 `PlaygroundView` 的扩展拆出，让主文件保持在 600 行以内。
//  依赖：SwiftUI、AppState、PlaygroundEngine、AIResultCard / PrimaryButton /
//        SurfaceCard / IconGlyph、PromptCatalog / PhraseStore（SharedBridge）。
//  使用方：PlaygroundView。
//

import SwiftUI

extension PlaygroundView {

    // MARK: - 生成按钮

    /// 底部主按钮 + 不可用原因。
    var generateButton: some View {
        VStack(spacing: AppMetrics.blockGap) {
            PrimaryButton(
                title: isImageFeature ? "生成图片" : "生成",
                systemImage: isImageFeature ? "photo.on.rectangle.angled" : "sparkles",
                tone: .accent,
                size: .large,
                isEnabled: canGenerate,
                isLoading: engine.isRunning,
                fullWidth: true
            ) {
                generate()
            }

            if !canGenerate {
                Text(generateDisabledReason)
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 是否可以生成。
    ///
    /// 除了「配置齐了」（`isChatReady` / `isImageReady`）之外，还必须**真的有一把能用的
    /// API Key**。此前只查 `isChatReady`，而它只看 baseURL + model 是否为空，
    /// 于是没填 Key 的服务商也能点亮「生成」，点下去只会弹一张失败卡片，
    /// 用户看到的就是「试验场点了没反应 / 不能用」。
    var canGenerate: Bool {
        !engine.isRunning
            && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isImageFeature ? appState.isImageReady : appState.isChatReady)
            && hasKeyForCurrentProvider
    }

    /// 当前选中的服务商是否已经填了 API Key。
    var hasKeyForCurrentProvider: Bool {
        guard let provider = currentPlaygroundProvider else { return false }
        let key = appState.apiKey(for: provider.id) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 当前选中的服务商（生图看生图列表，对话看对话列表）。
    var currentPlaygroundProvider: AIProviderConfig? {
        if isImageFeature {
            return appState.imageProviders.first(where: { $0.id == currentProviderID })
                ?? appState.imageProvider
        }
        return appState.chatProviders.first(where: { $0.id == currentProviderID })
            ?? appState.defaultChatProvider
    }

    /// 不能生成时的原因。
    var generateDisabledReason: String {
        if engine.isRunning {
            return "正在生成，请稍候…"
        }
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "先输入一段内容或描述"
        }
        if isImageFeature && !appState.isImageReady {
            return "请先在「设置 › AI 服务」里配置生图服务商（即梦 / 通义万相）"
        }
        if !isImageFeature && !appState.isChatReady {
            return "请先在「设置 › AI 服务」里配置一个对话服务商"
        }
        if let provider = currentPlaygroundProvider, !hasKeyForCurrentProvider {
            return "「\(provider.name)」还没有填 API Key，去「设置 › AI 服务」补上"
        }
        return ""
    }

    // MARK: - 结果

    /// 结果卡片（流式 / 完成 / 失败 / 绘制中 / 出图五种状态）。
    func resultSection(state: AIResultCard.ResultState) -> some View {
        AIResultCard(
            feature: feature,
            state: state,
            providerName: isImageFeature ? imageProviderName : chatProviderName,
            canRetry: true,
            onInsert: nil,
            onCopy: { copyResult(state) },
            onEdit: { saveAsPhrase(state) },
            onRetry: { generate() },
            onCancel: { engine.cancel() },
            onClose: {
                withAnimation(Theme.Motion.normalAnimation) {
                    engine.clear()
                }
            },
            onSaveToAlbum: { await saveImageToAlbum(state) }
        )
        .animation(Theme.Motion.spring, value: state)
    }

    // MARK: - 提示卡

    /// 空结果时的「可以试试」提示。
    var tipsCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                HStack(spacing: AppMetrics.tightGap) {
                    IconGlyph(
                        symbol: "lightbulb",
                        fallback: "💡",
                        size: AppMetrics.glyphSizeSmall,
                        weight: .semibold,
                        tint: Theme.warning
                    )
                    Text("可以试试")
                        .font(AppFont.headline)
                        .foregroundColor(Theme.textPrimary)
                }

                tipLine("把一句口语润色成更得体的书面语")
                tipLine("把中文消息翻译成英文邮件")
                tipLine("根据上下文生成 3 条回复候选")
                tipLine("描述一个画面，用即梦 / 万相画出来")

                Text("这里的所有请求都直接从本机发往你配置的服务商，不经过墨语的服务器。")
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppMetrics.hairGap)
            }
        }
    }

    /// 提示卡里的一行。
    func tipLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: AppMetrics.tightGap) {
            Circle()
                .fill(Theme.textTertiary)
                .frame(width: AppMetrics.hairline * 6, height: AppMetrics.hairline * 6)
                .padding(.top, AppMetrics.blockGap)
            Text(text)
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 逻辑

    /// 同步 AppState 里的默认值。
    func syncDefaults() {
        tone = appState.currentTone
        imageSize = appState.snapshot.imageSize
        if chatProviderID == nil {
            chatProviderID = appState.defaultChatProvider?.id
        }
        if imageProviderID == nil {
            imageProviderID = appState.imageProvider?.id
        }
        if targetLanguage.isEmpty {
            targetLanguage = TargetLanguageOption.suggested(for: inputText)
        }
        appState.refreshDerivedState()
    }

    /// 发起生成。
    func generate() {
        guard canGenerate else { return }
        isInputFocused = false
        Haptics.light()

        if isImageFeature {
            guard let provider = appState.imageProviders.first(where: { $0.id == currentProviderID })
                    ?? appState.imageProvider else {
                appState.showToast(ToastMessage(kind: .warning, text: "还没有可用的生图服务商"))
                return
            }
            engine.runImage(
                prompt: inputText,
                size: imageSize,
                provider: provider,
                apiKey: appState.apiKey(for: provider.id) ?? "",
                providerName: provider.name
            )
            return
        }

        guard let provider = appState.chatProviders.first(where: { $0.id == currentProviderID })
                ?? appState.defaultChatProvider else {
            appState.showToast(ToastMessage(kind: .warning, text: "还没有可用的对话服务商"))
            return
        }
        let template = templateID.flatMap { PromptCatalog.template(id: $0) }
        engine.runText(
            feature: feature,
            template: template,
            input: inputText,
            tone: tone,
            targetLanguage: targetLanguage,
            provider: provider,
            apiKey: appState.apiKey(for: provider.id) ?? ""
        )
    }

    /// 复制结果到剪贴板。
    func copyResult(_ state: AIResultCard.ResultState) {
        switch state {
        case .done(let text), .streaming(let text):
            guard !text.isEmpty else { return }
            UIPasteboard.general.string = text
            appState.showToast(ToastMessage(kind: .success, text: "已复制到剪贴板"))
            Haptics.success()
        case .image(let data):
            if let imageData = data.imageData, let image = UIImage(data: imageData) {
                UIPasteboard.general.image = image
                appState.showToast(
                    ToastMessage(
                        kind: .success,
                        text: "图片已复制",
                        detail: "回到聊天窗口长按输入框粘贴"
                    )
                )
                Haptics.success()
            } else {
                appState.showToast(ToastMessage(kind: .warning, text: "这张图暂时无法复制"))
            }
        case .failed, .imageGenerating:
            break
        }
    }

    /// 保存为快捷短语。
    func saveAsPhrase(_ state: AIResultCard.ResultState) {
        guard case .done(let text) = state, !text.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        PhraseStore.add(text: trimmed)
        appState.refreshPhraseCount()
        appState.showToast(
            ToastMessage(kind: .success, text: "已保存为短语", detail: "在键盘的短语面板里可以使用")
        )
        Haptics.success()
    }

    /// 把生图结果保存到系统相册。
    ///
    /// 权限只在用户点下「保存到相册」之后才申请（见 `PhotoLibrarySaver.save`），
    /// 这里只负责取图、调用与结果提示。被拒绝时给出可执行的设置路径，
    /// 而不是一句「保存失败」。
    @MainActor
    func saveImageToAlbum(_ state: AIResultCard.ResultState) async {
        guard case .image(let result) = state else { return }
        guard let imageData = result.imageData, let image = UIImage(data: imageData) else {
            appState.showToast(
                ToastMessage(
                    kind: .warning,
                    text: "这张图暂时无法保存",
                    detail: "可以先用「复制图片」，再粘贴到聊天窗口里。"
                )
            )
            return
        }
        do {
            try await PhotoLibrarySaver.save(image)
            Haptics.success()
            appState.showToast(
                ToastMessage(
                    kind: .success,
                    text: "已保存到相册",
                    detail: "可以在「照片」App 里找到这张图。"
                )
            )
        } catch {
            appState.showToast(
                ToastMessage(
                    kind: .warning,
                    text: PhotoLibrarySaver.message(for: error),
                    detail: PhotoLibrarySaver.suggestion(for: error)
                )
            )
            Haptics.warning()
        }
    }
}
