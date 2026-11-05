//
//  AIPrefs.swift
//  墨语 · AI 对话和画图的偏好、对话记录
//
//  App 的「AI 对话」页和键盘里的对话、画图都读这一份。
//

import Foundation

public struct AIPrefs: Codable, Equatable, Sendable {

    /// 想不想。
    public enum Reasoning: String, Codable, Sendable, CaseIterable {
        case auto, fast, deep

        public var title: String {
            switch self {
            case .auto: return "自动"
            case .fast: return "快速"
            case .deep: return "深度思考"
            }
        }

        public var level: ReasoningLevel? {
            switch self {
            case .auto: return nil
            case .fast: return .fast
            case .deep: return .deep
            }
        }
    }

    /// 回答多长。
    public enum Length: String, Codable, Sendable, CaseIterable {
        case short, medium, long

        public var title: String {
            switch self {
            case .short: return "简短"
            case .medium: return "适中"
            case .long: return "详细"
            }
        }

        public var maxTokens: Int {
            switch self {
            case .short: return 500
            case .medium: return 1200
            case .long: return 3000
            }
        }

        /// 写进系统提示里的话。
        public var instruction: String {
            switch self {
            case .short: return "回答尽量简短，三句话以内，不要列表。"
            case .medium: return "回答长度适中，说清楚就行。"
            case .long: return "可以详细展开，必要时分点说明。"
            }
        }
    }

    /// 画幅。
    public enum ImageShape: String, Codable, Sendable, CaseIterable {
        case square, portrait, landscape

        public var title: String {
            switch self {
            case .square: return "方图"
            case .portrait: return "竖图"
            case .landscape: return "横图"
            }
        }

        public var size: String {
            switch self {
            case .square: return "1024x1024"
            case .portrait: return "864x1152"
            case .landscape: return "1152x864"
            }
        }
    }

    /// 画风。
    public enum ImageStyle: String, Codable, Sendable, CaseIterable {
        case none, photo, illustration, anime, watercolor, threeD

        public var title: String {
            switch self {
            case .none: return "不限风格"
            case .photo: return "写实"
            case .illustration: return "插画"
            case .anime: return "动漫"
            case .watercolor: return "水彩"
            case .threeD: return "3D"
            }
        }

        /// 加在提示词后面。
        public var promptSuffix: String {
            switch self {
            case .none: return ""
            case .photo: return "，写实摄影风格，自然光"
            case .illustration: return "，扁平插画风格"
            case .anime: return "，日系动漫风格"
            case .watercolor: return "，水彩画风格"
            case .threeD: return "，3D 渲染风格"
            }
        }
    }

    /// 联网搜索。
    public enum WebSearchMode: String, Codable, Sendable, CaseIterable {
        case off, auto, always

        public var title: String {
            switch self {
            case .off: return "关"
            case .auto: return "自动"
            case .always: return "总是"
            }
        }
    }

    public var webSearch: WebSearchMode = .auto
    /// 画图失败时自动换别的模型。关掉就只用画图服务里选的那个（有的账号只有一个模型有额度）。
    public var imageModelAuto: Bool = true
    public var reasoning: Reasoning = .auto
    public var length: Length = .medium
    /// 人设，写进系统提示。空的话用默认。
    public var persona: String = ""
    /// 带上前面几轮对话（一问一答算一轮）。
    public var contextTurns: Int = 6
    /// 把对话存下来，App 里能看。
    public var keepHistory: Bool = true
    public var imageShape: ImageShape = .square
    public var imageStyle: ImageStyle = .none
    /// 画之前让写字的模型把描述写具体。
    public var polishImagePrompt: Bool = true
    /// 语音会话开着多久（分钟）。开着时键盘里长按空格就能说。
    public var voiceKeepAliveMinutes: Int = 5

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case reasoning, length, persona, contextTurns, keepHistory, imageShape, imageStyle, polishImagePrompt, voiceKeepAliveMinutes
        case webSearch, imageModelAuto
    }

    /// 容错解码：缺字段或值不认识都用默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AIPrefs()
        reasoning = (try? container.decodeIfPresent(Reasoning.self, forKey: .reasoning)) ?? fallback.reasoning
        length = (try? container.decodeIfPresent(Length.self, forKey: .length)) ?? fallback.length
        persona = (try? container.decodeIfPresent(String.self, forKey: .persona)) ?? fallback.persona
        contextTurns = (try? container.decodeIfPresent(Int.self, forKey: .contextTurns)) ?? fallback.contextTurns
        keepHistory = (try? container.decodeIfPresent(Bool.self, forKey: .keepHistory)) ?? fallback.keepHistory
        imageShape = (try? container.decodeIfPresent(ImageShape.self, forKey: .imageShape)) ?? fallback.imageShape
        imageStyle = (try? container.decodeIfPresent(ImageStyle.self, forKey: .imageStyle)) ?? fallback.imageStyle
        polishImagePrompt = (try? container.decodeIfPresent(Bool.self, forKey: .polishImagePrompt)) ?? fallback.polishImagePrompt
        voiceKeepAliveMinutes = (try? container.decodeIfPresent(Int.self, forKey: .voiceKeepAliveMinutes)) ?? fallback.voiceKeepAliveMinutes
        webSearch = (try? container.decodeIfPresent(WebSearchMode.self, forKey: .webSearch)) ?? fallback.webSearch
        imageModelAuto = (try? container.decodeIfPresent(Bool.self, forKey: .imageModelAuto)) ?? fallback.imageModelAuto
    }

    private static let key = "moyu.ai.prefs.v1"

    public static func load(from blob: SharedBlob = .shared) -> AIPrefs {
        guard let data = blob.data(forKey: key), let decoded = try? JSONDecoder().decode(AIPrefs.self, from: data) else {
            return AIPrefs()
        }
        return decoded
    }

    public func save(to blob: SharedBlob = .shared) {
        blob.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// 系统提示里追加的话。
    public var systemAddition: String {
        let trimmed = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        let personaLine = trimmed.isEmpty ? "" : "你的人设：\(trimmed)\n"
        return personaLine + length.instruction
    }

    /// 人设的几个现成写法。
    public static let personaPresets: [(title: String, text: String)] = [
        ("默认", ""),
        ("简洁助手", "说话直接，不客套，先给结论。"),
        ("写作帮手", "擅长改写和润色中文，语气自然，像真人说话。"),
        ("翻译官", "把用户的话翻成地道的英文，必要时给两种说法。"),
        ("知心朋友", "语气温和，先共情再给建议。")
    ]
}

/// 对话记录：键盘写，App 看。
public struct ChatHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var isUser: Bool
    public var text: String
    public var date: Date

    public init(id: UUID = UUID(), isUser: Bool, text: String, date: Date = Date()) {
        self.id = id
        self.isUser = isUser
        self.text = text
        self.date = date
    }
}

public enum ChatHistoryStore {
    private static let key = "moyu.ai.chatHistory.v1"
    public static let limit = 80

    public static func load(from blob: SharedBlob = .shared) -> [ChatHistoryEntry] {
        guard let data = blob.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ChatHistoryEntry].self, from: data) else { return [] }
        return decoded
    }

    public static func save(_ entries: [ChatHistoryEntry], to blob: SharedBlob = .shared) {
        let trimmed = Array(entries.suffix(limit))
        blob.set(trimmed.isEmpty ? nil : try? JSONEncoder().encode(trimmed), forKey: key)
    }
}
