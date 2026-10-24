//
//  PlaygroundParameterSection.swift
//  墨语 · 宿主 App
//
//  模块职责：「AI 试验场」的参数区 —— 服务商 / 语气 / 目标语言 / 生图尺寸 / 模板
//            的折叠面板与摘要文本。作为 `PlaygroundView` 的扩展拆出，
//            让主文件保持在 600 行以内。
//  依赖：SwiftUI、AppState、SettingsRow / SurfaceCard / PillChip / ToneSelector。
//  使用方：PlaygroundView。
//

import SwiftUI

extension PlaygroundView {

    // MARK: - 参数面板

    /// 折叠的参数面板：标题行显示摘要，展开后是各选择器。
    var parameterRow: some View {
        VStack(spacing: AppMetrics.blockGap) {
            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    SettingsRow(
                        icon: IconSpec(symbol: "slider.horizontal.3", tint: Theme.textSecondary),
                        title: "参数",
                        subtitle: parameterSummary,
                        accessory: .chevron
                    ) {
                        withAnimation(Theme.Motion.spring) {
                            showsParameters.toggle()
                        }
                    }

                    if showsParameters {
                        RowDivider()
                        VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                            providerPicker
                            RowDivider(hasIcon: false)

                            if isImageFeature {
                                imageSizePicker
                            } else {
                                toneSelector
                                RowDivider(hasIcon: false)
                                if feature == .translate {
                                    targetLanguagePicker
                                    RowDivider(hasIcon: false)
                                }
                                templatePicker
                            }
                        }
                        .padding(AppMetrics.cardPadding)
                    }
                }
            }
        }
    }

    /// 折叠状态下的参数摘要。
    var parameterSummary: String {
        if isImageFeature {
            return "\(imageProviderName) · \(ImageSizeOption.title(for: imageSize))"
        }
        return "\(chatProviderName) · 语气 \(tone)"
    }

    /// 当前对话服务商名。
    var chatProviderName: String {
        if let id = chatProviderID,
           let provider = appState.chatProviders.first(where: { $0.id == id }) {
            return provider.name
        }
        return appState.defaultChatProvider?.name ?? "未选择"
    }

    /// 当前生图服务商名。
    var imageProviderName: String {
        if let id = imageProviderID,
           let provider = appState.imageProviders.first(where: { $0.id == id }) {
            return provider.name
        }
        return appState.imageProvider?.name ?? "未选择"
    }

    /// 当前生效的服务商 ID。
    var currentProviderID: String? {
        if isImageFeature {
            return imageProviderID ?? appState.imageProvider?.id
        }
        return chatProviderID ?? appState.defaultChatProvider?.id
    }

    // MARK: - 选择器

    /// 服务商选择 chips。
    var providerPicker: some View {
        VStack(alignment: .leading, spacing: AppMetrics.tightGap) {
            Text(isImageFeature ? "生图服务商" : "对话服务商")
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)

            let candidates = isImageFeature ? appState.imageProviders : appState.chatProviders

            if candidates.isEmpty {
                Text("还没有可用的服务商，去「设置 › AI 服务」添加。")
                    .font(AppFont.caption)
                    .foregroundColor(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppMetrics.tightGap) {
                        ForEach(candidates) { provider in
                            PillChip(
                                provider.name,
                                style: .provider,
                                isSelected: currentProviderID == provider.id,
                                action: {
                                    if isImageFeature {
                                        imageProviderID = provider.id
                                    } else {
                                        chatProviderID = provider.id
                                    }
                                    Haptics.selection()
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    /// 语气选择器。
    var toneSelector: some View {
        VStack(alignment: .leading, spacing: AppMetrics.tightGap) {
            Text("语气")
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)
            ToneSelector(selected: tone) { selected in
                tone = selected
            }
            .padding(.horizontal, -AppMetrics.pageInset)
        }
    }

    /// 翻译目标语言。
    var targetLanguagePicker: some View {
        VStack(alignment: .leading, spacing: AppMetrics.tightGap) {
            Text("目标语言")
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppMetrics.tightGap) {
                    ForEach(TargetLanguageOption.all) { option in
                        PillChip(
                            option.title,
                            style: .tag,
                            isSelected: targetLanguage == option.title,
                            action: {
                                targetLanguage = option.title
                                Haptics.selection()
                            }
                        )
                    }
                }
            }
        }
    }

    /// 生图尺寸。
    var imageSizePicker: some View {
        VStack(alignment: .leading, spacing: AppMetrics.tightGap) {
            Text("尺寸")
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppMetrics.tightGap) {
                    ForEach(ImageSizeOption.all) { option in
                        PillChip(
                            option.title,
                            style: .tag,
                            isSelected: imageSize == option.size,
                            action: {
                                imageSize = option.size
                                Haptics.selection()
                            }
                        )
                    }
                }
            }
        }
    }

    /// 模板选择（内置 + 自定义）。
    var templatePicker: some View {
        VStack(alignment: .leading, spacing: AppMetrics.tightGap) {
            Text("模板")
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)

            let templates = availableTemplates

            if templates.isEmpty {
                Text("该能力暂无模板，将使用默认提示词。")
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textTertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppMetrics.tightGap) {
                        PillChip(
                            "默认",
                            style: .tool,
                            isSelected: templateID == nil,
                            action: {
                                templateID = nil
                                Haptics.selection()
                            }
                        )
                        ForEach(templates) { template in
                            PillChip(
                                template.title,
                                style: .tool,
                                isSelected: templateID == template.id,
                                action: {
                                    templateID = template.id
                                    Haptics.selection()
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    /// 当前能力可用的模板（内置 + 自定义）。
    var availableTemplates: [PromptTemplate] {
        PromptCatalog.templates(for: feature) + PromptCatalog.custom.filter { $0.feature == feature }
    }
}
