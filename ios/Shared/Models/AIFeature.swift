//
//  AIFeature.swift
//  ios/Shared/Models
//
//  模块职责：声明键盘内可一键调用的 AI 能力集合（润色/扩写/翻译/回复建议/生图/自定义），
//            并提供中文标题、SF Symbol 与默认 Prompt 模板 ID。
//  依赖：仅 Foundation。
//  使用方：键盘扩展（AIBar / KeyboardViewModel.startAI）、宿主 App（PlaygroundView /
//          PromptLibraryView）、Prompts（PromptLibrary.templates(feature:)）。
//

import Foundation

/// 键盘内可一键调用的 AI 能力。
public enum AIFeature: String, Codable, CaseIterable, Sendable {
    /// 润色：顺句、改错、自然化，长度与原句相近。
    case polish
    /// 扩写：一句话扩成 2~4 句，保留原意不编造。
    case expand
    /// 翻译：自动识别方向，可指定目标语言（中/英/日/韩）。
    case translate
    /// 回复建议：给出恰好 3 条可直接发送的回复。
    case replySuggestion
    /// 生图：文本提示词 → 图片。
    case image
    /// 自定义：使用用户自己的 Prompt 模板。
    case custom

    /// 中文标题（工具条 chip 与标题栏使用）。
    public var title: String {
        switch self {
        case .polish:
            return "润色"
        case .expand:
            return "扩写"
        case .translate:
            return "翻译"
        case .replySuggestion:
            return "回复建议"
        case .image:
            return "生图"
        case .custom:
            return "自定义"
        }
    }

    /// 工具条 chip 使用的 SF Symbol 名称。
    public var systemImage: String {
        switch self {
        case .polish:
            return "wand.and.stars"
        case .expand:
            return "text.append"
        case .translate:
            return "character.bubble"
        case .replySuggestion:
            return "bubble.left.and.bubble.right"
        case .image:
            return "photo.on.rectangle.angled"
        case .custom:
            return "square.and.pencil"
        }
    }

    /// chip / 面板使用的短说明（VoiceOver 与空态提示）。
    public var summary: String {
        switch self {
        case .polish:
            return "把这句话说得更顺、更自然"
        case .expand:
            return "一句话扩成完整表达"
        case .translate:
            return "中英日韩互译，只输出译文"
        case .replySuggestion:
            return "根据对方消息给出 3 条回复"
        case .image:
            return "把描述变成图片，复制后长按粘贴"
        case .custom:
            return "使用你自己的 Prompt 模板"
        }
    }

    /// 默认 Temperatur（越需要稳定越低温）。
    public var defaultTemperature: Double {
        switch self {
        case .polish, .translate:
            return 0.4
        case .expand, .replySuggestion:
            return 0.8
        case .image:
            return 0.7
        case .custom:
            return 0.7
        }
    }

    /// 是否必须使用生图客户端（而不是文本对话客户端）。
    public var usesImageClient: Bool {
        self == .image
    }

    /// 该能力默认对应的内置模板 ID（`PromptLibrary.builtIn` 中的 `id`）。
    public var defaultTemplateID: String {
        switch self {
        case .polish:
            return "builtin.polish"
        case .expand:
            return "builtin.expand"
        case .translate:
            return "builtin.translate"
        case .replySuggestion:
            return "builtin.reply"
        case .image:
            return "builtin.image.prompt"
        case .custom:
            return "builtin.custom"
        }
    }
}
