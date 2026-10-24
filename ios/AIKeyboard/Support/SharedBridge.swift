//
//  SharedBridge.swift
//  墨语 · 宿主 App
//
//  模块职责：宿主 App 与 Shared 层之间的**唯一集成缝**。
//            所有对 Shared 的跨模块调用（PromptLibrary / PhraseLibrary / PinyinDictionary /
//            PasteboardBridge / AIClientFactory）都收敛在这里，便于：
//            1) 契约变更时只改一处；
//            2) 静态审查时快速核对符号是否存在；
//            3) README 里精确列出"依赖的 Shared 符号清单"。
//  依赖：Shared（Models / Storage / Networking / Prompts / IMECore）。
//  使用方：AppState / Playground / Diagnostics / PromptLibraryView / SettingsView。
//

import Foundation

// MARK: - Prompt 目录

/// Prompt 模板访问入口（转发 `PromptLibrary`）。
enum PromptCatalog {

    /// 全部内置模板。
    static var builtIn: [PromptTemplate] {
        PromptLibrary.builtIn
    }

    /// 某个能力下的模板（内置 + 自定义由调用方自行拼接）。
    static func templates(for feature: AIFeature) -> [PromptTemplate] {
        PromptLibrary.templates(feature: feature)
    }

    /// 用户自定义模板。
    static var custom: [PromptTemplate] {
        PromptLibrary.loadCustom()
    }

    /// 保存用户自定义模板。
    static func saveCustom(_ templates: [PromptTemplate]) {
        PromptLibrary.saveCustom(templates)
    }

    /// 把模板渲染成消息列表。
    static func render(
        _ template: PromptTemplate,
        text: String,
        context: String,
        tone: String,
        targetLanguage: String
    ) -> [ChatMessage] {
        PromptLibrary.render(
            template,
            text: text,
            context: context,
            tone: tone,
            targetLanguage: targetLanguage
        )
    }

    /// 按 ID 找模板（先内置后自定义）。
    static func template(id: String) -> PromptTemplate? {
        if let matched = builtIn.first(where: { $0.id == id }) {
            return matched
        }
        return custom.first { $0.id == id }
    }
}

// MARK: - 短语

/// 短语库访问入口（转发 `PhraseLibrary`）。
enum PhraseStore {

    /// 短语库实例（`SharedStore` 单例，App 与扩展共用同一份存储）。
    private static let library = PhraseLibrary(store: SharedStore.shared)

    /// 全部短语（置顶优先）。
    static var items: [PhraseItem] {
        library.items
    }

    /// 新增或更新。
    static func upsert(_ item: PhraseItem) {
        library.upsert(item)
    }

    /// 删除。
    static func remove(id: String) {
        library.remove(id: id)
    }

    /// 用纯文本快速建一条短语（key 留空表示不设快捷触发词）。
    @discardableResult
    static func add(text: String, key: String = "") -> PhraseItem {
        let item = PhraseItem(
            id: UUID().uuidString,
            key: key.trimmingCharacters(in: .whitespacesAndNewlines),
            text: text,
            isPinned: false
        )
        library.upsert(item)
        return item
    }

    /// 短语条数。
    static var count: Int {
        library.items.count
    }
}

// MARK: - 词库信息

/// 拼音词库信息（只读，用于首页与诊断页展示）。
///
/// CONTRACT-ADD（真机排查）：除了版本与词条数，还带上**词库来源**。
/// 键盘打不出中文时，`PinyinDictionary` 会静默回退到 50 条内置小词表而不报错，
/// 所以"来源"是判断「词库到底有没有打进包」的唯一现场证据（见 `IMEKit.dictionarySource`）。
struct DictionaryInfo: Equatable {

    /// 词库版本号。
    var version: String

    /// 词条数量。
    var wordCount: Int

    /// 词库来源（打包词库 / 内置兜底 / 内存）。
    var source: IMEKit.DictionarySource

    /// 词库在 Bundle 内的相对路径（如 `dict/base_dict.tsv`），兜底时为 `<builtin>`。
    var relativePath: String

    /// 词库加载耗时（毫秒）。
    var loadDurationMilliseconds: Double

    /// 词库是否可用（加载失败时为 nil）。
    ///
    /// 说明：`PinyinDictionary` 在词库缺失时会用内置兜底词表，此时 `version` 不为空，
    /// 因此这里不能在兜底时返回 nil —— 兜底本身就是"需要展示给用户"的诊断信息。
    static func current() -> DictionaryInfo? {
        let kit = sharedKit
        let version = kit.dictionaryVersion
        guard !version.isEmpty else { return nil }
        return DictionaryInfo(
            version: version,
            wordCount: kit.wordCount,
            source: kit.dictionarySource,
            relativePath: kit.dictionaryRelativePath,
            loadDurationMilliseconds: kit.loadDurationMilliseconds
        )
    }

    /// 进程内共享的输入法内核（惰性创建一次）。
    ///
    /// `IMEKit` 的构造会加载学习数据、短语库与上下文索引，不适合每次刷新都新建；
    /// 而 `refreshDerivedState()` 会在启动/改配置/回到前台时多次调用，因此在
    /// 这里缓存一份（`PinyinDictionary` 本身也是进程内单例，不会重复读盘）。
    private static let sharedKit = IMEKit(store: SharedStore.shared)

    /// 形式化的词条数量，例如 "12.6 万"。
    var formattedWordCount: String {
        if wordCount >= 10_000 {
            let value = Double(wordCount) / 10_000
            return String(format: "%.1f 万", value)
        }
        return "\(wordCount)"
    }

    /// 词库来源的中文描述（正常 / 告警两种语气）。
    var sourceDescription: String {
        switch source {
        case .bundled:
            return "打包词库"
        case .builtin:
            return "⚠️ 内置兜底词库（安装包可能缺词库）"
        case .memory:
            return "内存内置"
        }
    }

    /// 是否退回到内置小词表（`true` 表示词库没打进包，中文候选会非常少）。
    var isUsingBuiltin: Bool {
        source == .builtin
    }

    /// 一句话完整摘要，例如：
    /// `词库 v1.0.0｜5276 条｜来源：打包词库｜路径：dict/base_dict.tsv｜加载 12.3ms`
    var summary: String {
        let duration = String(format: "%.1f", loadDurationMilliseconds)
        return "词库 v\(version)｜\(wordCount) 条｜来源：\(sourceDescription)"
            + "｜路径：\(relativePath)｜加载 \(duration)ms"
    }
}

// MARK: - 配置导出

/// 配置导出结果。
enum ConfigExportResult {
    case success
    case failure(String)
}

/// 配置搬运入口（转发 `PasteboardBridge`）。
enum ConfigExporter {

    /// 命名剪贴板名称（展示用）。
    static var pasteboardName: String {
        PasteboardBridge.pasteboardName.rawValue
    }

    /// 导出快照到命名剪贴板。
    static func export(_ snapshot: ConfigSnapshot, includeAPIKeys: Bool) -> ConfigExportResult {
        do {
            try PasteboardBridge.export(snapshot, includeAPIKeys: includeAPIKeys)
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// 从命名剪贴板导入快照（App 侧一般用不到，保留给"粘贴导入"入口）。
    static func importSnapshot() -> ConfigSnapshot? {
        PasteboardBridge.importSnapshot()
    }

    /// 当前是否具备 App Group（免费账号通常为 false）。
    static var isAppGroupAvailable: Bool {
        SharedStore.shared.isAppGroupAvailable
    }
}

// MARK: - 连接测试

/// 连通性 / 服务可用性探测。
enum ConnectivityProbe {

    /// Apple 官方网络探测地址（HTTP 204/200 即视为联网正常）。
    static let probeURL = URL(string: "https://www.apple.com/library/test/success.html")

    /// 联网探测结果。
    struct Result {
        /// 是否可联网。
        var isReachable: Bool
        /// 中文描述。
        var detail: String
        /// 往返耗时（秒），失败时为 nil。
        var latency: TimeInterval?
    }

    /// 直接探测公网连通性。
    static func checkNetwork(timeout: TimeInterval = 8) async -> Result {
        guard let url = probeURL else {
            return Result(isReachable: false, detail: "探测地址无效", latency: nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(start)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) || code == 204 {
                return Result(
                    isReachable: true,
                    detail: "已联网（HTTP \(code)）",
                    latency: elapsed
                )
            }
            return Result(isReachable: false, detail: "网络返回异常状态码 \(code)", latency: elapsed)
        } catch {
            return Result(isReachable: false, detail: "无法联网：\(error.localizedDescription)", latency: nil)
        }
    }

    /// 构造一条「hi」探活流（不落任何状态，由调用方消费）。
    static func makeHelloStream(
        config: AIProviderConfig,
        apiKey: String
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        let client = AIClientFactory.makeLLM(config: config, apiKey: apiKey)
        let request = ChatRequest(
            messages: [ChatMessage.user("hi")],
            temperature: 0,
            maxTokens: 8,
            stream: true
        )
        return client.stream(request)
    }

    /// 发起一次真实生图请求（供试验场 / 诊断页使用）。
    static func generateImage(
        config: AIProviderConfig,
        apiKey: String,
        prompt: String,
        size: String
    ) async throws -> [GeneratedImage] {
        let client = AIClientFactory.makeImage(config: config, apiKey: apiKey)
        let request = ImageRequest(prompt: prompt, size: size, quality: "standard", count: 1)
        return try await client.generate(request)
    }
}

// MARK: - 键盘扩展心跳

/// 键盘扩展「最近一次被使用」的时间戳读取入口。
///
/// 背景：iOS 不提供「本键盘是否已被添加到系统键盘列表」的查询 API。
/// 可行的启发式做法是：键盘扩展每次被唤起 / 联网成功时，往共享存储写一个时间戳，
/// 宿主 App 读这个时间戳来判断"大概用过"。
///
/// **协作约定**：这两个 key 由键盘扩展（ime-core / keyboard-ui）负责写入，
/// 宿主 App 只读。若扩展尚未实现写入，App 侧一律展示"可能未开启 + 如何确认"，
/// 不能断言"未添加"。
enum ExtensionTelemetry {

    /// 扩展最近一次被唤起的时间戳（Unix 秒，Double）。
    static let heartbeatKey = "moyu.ext.lastActiveAt"

    /// 扩展最近一次联网成功的时间戳（Unix 秒，Double）。
    static let networkOKKey = "moyu.ext.lastNetworkOKAt"

    /// 心跳被视为"新鲜"的时长（24 小时）。
    static let freshness: TimeInterval = 24 * 60 * 60

    /// 最近一次被使用的时间；没有记录返回 nil。
    static func lastActiveAt() -> Date? {
        date(forKey: heartbeatKey)
    }

    /// 最近一次联网成功的时间；没有记录返回 nil。
    static func lastNetworkOKAt() -> Date? {
        date(forKey: networkOKKey)
    }

    /// 24 小时内是否被使用过（nil 视为 unknown，由调用方决定文案）。
    static var isRecentlyActive: Bool {
        guard let date = lastActiveAt() else { return false }
        return Date().timeIntervalSince(date) <= freshness
    }

    /// 24 小时内是否联网成功过。
    static var hasRecentNetworkSuccess: Bool {
        guard let date = lastNetworkOKAt() else { return false }
        return Date().timeIntervalSince(date) <= freshness
    }

    /// 把时间戳转成中文相对描述，例如「3 小时前」。
    static func relativeDescription(_ date: Date?) -> String {
        guard let date else { return "没有记录" }
        let seconds = max(Date().timeIntervalSince(date), 0)
        if seconds < 60 {
            return "刚刚"
        }
        if seconds < 3600 {
            return "\(Int(seconds / 60)) 分钟前"
        }
        if seconds < 86_400 {
            return "\(Int(seconds / 3600)) 小时前"
        }
        return "\(Int(seconds / 86_400)) 天前"
    }

    /// 读取并解析时间戳。
    private static func date(forKey key: String) -> Date? {
        let raw = SharedStore.shared.double(forKey: key, default: 0)
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }
}

// MARK: - 错误文案

/// 把任意错误转成「一句话 + 可执行建议」的中文文案。
enum ErrorPresenter {

    /// 中文主文案。
    static func message(_ error: Error) -> String {
        if let aiError = error as? AIError {
            return aiError.errorDescription ?? "请求失败，请稍后重试。"
        }
        return error.localizedDescription
    }

    /// 中文修复建议（可能为空）。
    static func suggestion(_ error: Error) -> String? {
        if let aiError = error as? AIError {
            return aiError.recoverySuggestion
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "请检查 Wi-Fi 或蜂窝网络后重试。"
            case NSURLErrorTimedOut:
                return "网络较慢或服务商响应超时，可稍后重试或调大超时时间。"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "域名解析或连接失败，请检查 baseURL 是否正确、是否需要代理。"
            default:
                return "请检查网络与 baseURL 后重试。"
            }
        }
        return nil
    }
}
