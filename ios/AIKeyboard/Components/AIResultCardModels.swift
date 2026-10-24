//
//  AIResultCardModels.swift
//  墨语 · 宿主 App 组件
//
//  「AI 结果卡」使用的三个值类型（契约：design/组件库.md §3.5）：
//  失败态数据、生图进度、已出图数据。
//  与 `AIResultCard.swift` 拆开放，让卡片视图文件保持在 600 行以内。
//  依赖：Foundation、AIError / GeneratedImage（Shared）。
//

import Foundation

/// 失败态需要展示的数据。
struct AIErrorViewData: Equatable {
    /// 主标题（一般是 AIError.errorDescription）。
    var title: String
    /// 补充说明（可空）。
    var message: String?
    /// 可执行建议（一般是 AIError.recoverySuggestion）。
    var suggestion: String?

    init(title: String, message: String? = nil, suggestion: String? = nil) {
        self.title = title
        self.message = message
        self.suggestion = suggestion
    }

    /// 从 AIError 构造（全中文文案由 Shared 层负责）。
    init(error: AIError) {
        self.title = ErrorPresenter.message(error)
        self.message = nil
        self.suggestion = ErrorPresenter.suggestion(error)
    }

    /// 通用兜底文案。
    static let generic = AIErrorViewData(
        title: "生成失败",
        message: "换个描述或稍后重试",
        suggestion: nil
    )
}

/// 生图进度。
struct ImageProgress: Equatable {

    /// 生图阶段。
    enum Stage: Equatable {
        /// 排队中。
        case queued
        /// 正在绘制。
        case drawing
        /// 正在优化提示词。
        case enhancing
        /// 正在下载。
        case downloading

        /// 阶段中文名。
        var title: String {
            switch self {
            case .queued: return "排队中"
            case .drawing: return "正在绘制"
            case .enhancing: return "正在优化提示词"
            case .downloading: return "正在下载"
            }
        }
    }

    /// 提示词（增强后的英文提示词也可放这里）。
    var prompt: String
    /// 已等待秒数（外部可累加，视图内部也会按开始时间自增）。
    var elapsed: TimeInterval
    /// 预计耗时区间，契约固定 5…20 秒。
    var expected: ClosedRange<TimeInterval>
    /// 当前阶段。
    var stage: Stage

    init(
        prompt: String,
        elapsed: TimeInterval = 0,
        expected: ClosedRange<TimeInterval> = 5...20,
        stage: Stage = .queued
    ) {
        self.prompt = prompt
        self.elapsed = elapsed
        self.expected = expected
        self.stage = stage
    }

    /// 进度环填充比例，最多到 0.9，避免看起来「卡在满格」。
    var progressFraction: Double {
        let base = max(expected.lowerBound, 0.1)
        let raw = elapsed / base
        return min(max(raw, 0.02), 0.9)
    }

    /// 是否已超过预计上限。
    var isOverdue: Bool {
        elapsed > expected.upperBound
    }
}

/// 已出图需要展示的数据。
struct ImageResultViewData: Equatable {
    /// 图片二进制（优先使用）。
    var imageData: Data?
    /// 远程地址（没有二进制时兜底，宿主 App 允许网络图片；键盘扩展不会用到）。
    var remoteURL: URL?
    /// 提示词。
    var prompt: String
    /// 尺寸描述，如「1024×1024」。
    var sizeDescription: String

    init(imageData: Data?, remoteURL: URL? = nil, prompt: String, sizeDescription: String = "") {
        self.imageData = imageData
        self.remoteURL = remoteURL
        self.prompt = prompt
        self.sizeDescription = sizeDescription
    }

    /// 从 Shared 层产物构造。
    init(image: GeneratedImage, prompt: String, sizeDescription: String = "") {
        self.imageData = image.data
        self.remoteURL = image.remoteURL
        self.prompt = prompt
        self.sizeDescription = sizeDescription
    }
}
