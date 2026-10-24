//
//  AppState.swift
//  墨语 · 宿主 App
//
//  模块职责：宿主 App 的唯一状态中枢。
//            - 持有配置快照（读写全部委托给 Shared/Storage 的 `ConfigStore`，本类**不**重复实现持久化）
//            - 派生派生列表（对话服务商 / 生图服务商）
//            - 当前 Tab、外观模式、首次启动标记、Toast
//  依赖：Shared（ConfigSnapshot / AIProviderConfig / ConfigStoring / KeychainStore / SharedStore）。
//  使用方：AIKeyboardApp（注入 environmentObject）、RootView 及全部页面。
//

import SwiftUI

/// 宿主 App 状态中枢。
///
/// 设计约束（见 README「与共享层的对接点」）：
/// 配置的**唯一真相**是 `Shared/Storage/ConfigStore` 写下的 `ConfigSnapshot`；
/// `AppState` 只是把它读进内存、暴露给 SwiftUI，并在修改后写回。
@MainActor
final class AppState: ObservableObject {

    // MARK: - 发布状态

    /// 当前配置快照。
    @Published private(set) var snapshot: ConfigSnapshot

    /// 当前选中的 Tab。
    @Published var selectedTab: MainTab = .keyboard

    /// 是否已完成首次引导。
    @Published var hasCompletedOnboarding: Bool

    /// 外观模式。
    @Published var appearanceMode: AppearanceMode {
        didSet { persistAppearance() }
    }

    /// 当前悬浮提示（nil 表示不显示）。
    @Published var toast: ToastMessage?

    /// 拼音词库信息（懒加载，失败为 nil）。
    @Published private(set) var dictionaryInfo: DictionaryInfo?

    /// 短语条数（缓存，避免每次渲染都读存储）。
    @Published private(set) var phraseCount: Int = 0

    /// 键盘扩展是否已安装（启发式检测结果）。
    @Published private(set) var isExtensionInstalled: Bool = false

    /// 键盘扩展最近一次被使用的时间（由扩展写入心跳，App 只读）。
    @Published private(set) var extensionLastActiveAt: Date?

    /// 键盘扩展最近一次联网成功的时间。
    @Published private(set) var extensionLastNetworkOKAt: Date?

    /// Keychain 是否可用。
    @Published private(set) var isKeychainAvailable: Bool = true

    // MARK: - 依赖

    /// 配置存储（Shared 层实现）。
    private let configStore: ConfigStoring

    /// 偏好存储（首次启动标记 / 外观模式）。
    private let preferences: UserDefaults

    // MARK: - 存储键

    private enum Keys {
        static let onboarding = "moyu.host.hasCompletedOnboarding"
        static let appearance = "moyu.host.appearanceMode"
    }

    // MARK: - 初始化

    /// 用共享存储构造。
    /// - Parameter configStore: 配置存储；默认使用 Shared 层的 `ConfigStore`。
    init(configStore: ConfigStoring? = nil) {
        let store = configStore ?? AppState.makeDefaultConfigStore()
        let prefs = SharedStore.shared.defaults
        let loaded = store.load()

        self.configStore = store
        self.preferences = prefs
        self.snapshot = loaded
        self.hasCompletedOnboarding = prefs.bool(forKey: Keys.onboarding)
        self.appearanceMode = AppState.decodeAppearance(prefs.string(forKey: Keys.appearance))

        refreshDerivedState()

        // 记录首次运行日期（用于估算免费签名剩余天数）。
        SignatureClock.markFirstRunIfNeeded()
    }

    /// **唯一的** `ConfigStore` 实例化点。
    ///
    /// 若 Shared 层后续修改了 `ConfigStore` 的构造签名，只需改这一行。
    private static func makeDefaultConfigStore() -> ConfigStoring {
        ConfigStore()
    }

    private static func decodeAppearance(_ raw: String?) -> AppearanceMode {
        guard let raw, let mode = AppearanceMode(rawValue: raw) else { return .system }
        return mode
    }

    // MARK: - 派生数据

    /// 全部服务商。
    var providers: [AIProviderConfig] {
        snapshot.providers
    }

    /// 可用于文本对话的服务商（过滤掉仅生图预设）。
    var chatProviders: [AIProviderConfig] {
        snapshot.providers.filter { $0.supportsChat }
    }

    /// 可用于生图的服务商。
    var imageProviders: [AIProviderConfig] {
        snapshot.providers.filter { $0.supportsImage }
    }

    /// 默认对话服务商。
    var defaultChatProvider: AIProviderConfig? {
        snapshot.defaultProvider
    }

    /// 默认生图服务商。
    var imageProvider: AIProviderConfig? {
        snapshot.imageProvider
    }

    /// 对话是否已配置好（有 baseURL + 模型）。
    var isChatReady: Bool {
        snapshot.isChatReady
    }

    /// 生图是否已配置好。
    var isImageReady: Bool {
        snapshot.isImageReady
    }

    /// 默认对话服务商是否已存 API Key。
    var hasDefaultChatAPIKey: Bool {
        guard let provider = defaultChatProvider else { return false }
        return hasAPIKey(for: provider.id)
    }

    /// 默认生图服务商是否已存 API Key。
    var hasImageAPIKey: Bool {
        guard let provider = imageProvider else { return false }
        return hasAPIKey(for: provider.id)
    }

    /// 当前是否"开箱即用"（对话配置齐全且有 Key）。
    var isReadyForAI: Bool {
        isChatReady && hasDefaultChatAPIKey
    }

    /// 默认语气的安全取值。
    var currentTone: String {
        let tone = snapshot.defaultTone
        return ToneOption.all.contains(tone) ? tone : ToneOption.fallback
    }

    /// 键盘安装/配置的整体状态（启发式，三态）。
    var keyboardSetupState: KeyboardSetupState {
        if !isChatReady {
            return .notConfigured
        }
        if ExtensionTelemetry.isRecentlyActive && hasDefaultChatAPIKey {
            return .ready
        }
        return .partial
    }

    /// 状态卡的一句话说明。
    var keyboardStatusDetail: String {
        switch keyboardSetupState {
        case .ready:
            return "键盘近 24 小时被使用过，AI 服务已配置"
        case .partial:
            if !hasDefaultChatAPIKey {
                return "还差一步：给「\(defaultChatProvider?.name ?? "默认服务商")」填 API Key"
            }
            if extensionLastActiveAt == nil {
                return "还没检测到键盘被使用，可能未添加"
            }
            return "上次使用：\(ExtensionTelemetry.relativeDescription(extensionLastActiveAt))，若已添加可忽略"
        case .notConfigured:
            return "还没有配置 AI 服务，配置后键盘里才能用 AI"
        }
    }

    // MARK: - 刷新派生状态

    /// 重新计算依赖存储的派生状态（词库 / 短语数 / 扩展安装 / Keychain / 扩展心跳）。
    func refreshDerivedState() {
        dictionaryInfo = DictionaryInfo.current()
        phraseCount = PhraseStore.count
        isKeychainAvailable = KeychainStore.shared.isAvailable
        isExtensionInstalled = ExtensionDetector.isInstalled()
        extensionLastActiveAt = ExtensionTelemetry.lastActiveAt()
        extensionLastNetworkOKAt = ExtensionTelemetry.lastNetworkOKAt()
    }

    // MARK: - 配置读写

    /// 重新从存储加载快照（用于"其它入口改了配置"后同步）。
    func reload() {
        objectWillChange.send()
        snapshot = configStore.load()
        refreshDerivedState()
    }

    /// 对快照做一次原子修改并持久化。
    /// - Parameter mutate: 修改闭包，直接改传入的快照副本。
    func updateSnapshot(_ mutate: (inout ConfigSnapshot) -> Void) {
        var copy = snapshot
        mutate(&copy)
        copy.version = ConfigSnapshot.currentVersion
        snapshot = copy
        configStore.save(copy)
    }

    /// 新增或更新一个服务商。
    func upsertProvider(_ provider: AIProviderConfig) {
        updateSnapshot { snapshot in
            if let index = snapshot.providers.firstIndex(where: { $0.id == provider.id }) {
                snapshot.providers[index] = provider
            } else {
                snapshot.providers.append(provider)
            }
        }
    }

    /// 删除一个服务商（同时清理其 API Key 与默认项引用）。
    func deleteProvider(id: String) {
        try? KeychainStore.shared.deleteAPIKey(for: id)
        updateSnapshot { snapshot in
            snapshot.providers.removeAll { $0.id == id }
            if snapshot.defaultProviderID == id {
                snapshot.defaultProviderID = snapshot.providers.first { $0.supportsChat }?.id
            }
            if snapshot.imageProviderID == id {
                snapshot.imageProviderID = snapshot.providers.first { $0.supportsImage }?.id
            }
        }
        showToast(.init(kind: .info, text: "已删除该服务商"))
    }

    /// 设为默认**对话**服务商（仅生图服务商会被拒绝并提示）。
    @discardableResult
    func setDefaultChatProvider(id: String) -> Bool {
        guard let provider = snapshot.providers.first(where: { $0.id == id }) else { return false }
        guard provider.supportsChat else {
            let reason = ProviderKindHint.unsupportedChatReason(provider)
                ?? "该服务仅支持生图，不能用于文本对话。"
            showToast(.init(kind: .warning, text: "无法设为对话服务商", detail: reason))
            return false
        }
        updateSnapshot { snapshot in
            snapshot.defaultProviderID = id
            for index in snapshot.providers.indices {
                snapshot.providers[index].isDefault = (snapshot.providers[index].id == id)
            }
        }
        return true
    }

    /// 设为默认**生图**服务商。
    @discardableResult
    func setDefaultImageProvider(id: String) -> Bool {
        guard let provider = snapshot.providers.first(where: { $0.id == id }) else { return false }
        guard provider.supportsImage else {
            showToast(.init(kind: .warning, text: "该服务商没有配置生图模型", detail: "请先在编辑页填写「生图模型」，或在预设里选择「即梦 · 火山方舟 / 通义万相」。"))
            return false
        }
        updateSnapshot { snapshot in
            snapshot.imageProviderID = id
            // 生图服务商与对话默认项解耦，不改动 isDefault。
        }
        return true
    }

    /// 修改一个开关型偏好。
    func setClipboardHistoryEnabled(_ enabled: Bool) {
        updateSnapshot { $0.enableClipboardHistory = enabled }
    }

    /// 修改本地学习开关。
    func setLearningEnabled(_ enabled: Bool) {
        updateSnapshot { $0.enableLearning = enabled }
    }

    /// 修改默认语气。
    func setDefaultTone(_ tone: String) {
        updateSnapshot { $0.defaultTone = tone }
    }

    /// 修改回复建议条数。
    func setReplyCount(_ count: Int) {
        updateSnapshot { $0.replyCount = min(max(count, 1), 5) }
    }

    /// 修改默认生图尺寸。
    func setImageSize(_ size: String) {
        updateSnapshot { $0.imageSize = size }
    }

    /// 恢复为"只含内置预设"的出厂配置。
    func resetToPresetOnly() {
        let preset = ConfigSnapshot.presetOnly()
        snapshot = preset
        configStore.save(preset)
        refreshDerivedState()
        showToast(.init(kind: .info, text: "已恢复默认服务商列表", detail: "API Key 不会随配置重置，需要重新填写。"))
    }

    // MARK: - API Key

    /// 读取某个服务商的 API Key（可能为 nil）。
    func apiKey(for providerID: String) -> String? {
        KeychainStore.shared.apiKey(for: providerID)
    }

    /// 该服务商是否已保存 API Key。
    func hasAPIKey(for providerID: String) -> Bool {
        guard let key = KeychainStore.shared.apiKey(for: providerID) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 保存 API Key 到钥匙串。
    /// - Returns: 是否成功；失败时会自动弹出 Toast。
    @discardableResult
    func saveAPIKey(_ key: String, for providerID: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast(.init(kind: .warning, text: "API Key 不能为空"))
            return false
        }
        do {
            try KeychainStore.shared.setAPIKey(trimmed, for: providerID)
            objectWillChange.send()
            showToast(.init(kind: .success, text: "API Key 已保存到钥匙串"))
            return true
        } catch {
            showToast(.init(kind: .failure, text: "保存 API Key 失败", detail: error.localizedDescription))
            return false
        }
    }

    /// 删除某个服务商的 API Key。
    func deleteAPIKey(for providerID: String) {
        do {
            try KeychainStore.shared.deleteAPIKey(for: providerID)
            objectWillChange.send()
            showToast(.init(kind: .info, text: "已删除该服务商的 API Key"))
        } catch {
            showToast(.init(kind: .failure, text: "删除 API Key 失败", detail: error.localizedDescription))
        }
    }

    // MARK: - 配置同步

    /// 导出配置到命名剪贴板。
    /// - Parameter includeAPIKeys: 是否连同 API Key 一起导出（默认否，风险高）。
    /// - Returns: 成功与否；成功时已弹出可读提示。
    @discardableResult
    func exportConfigToKeyboard(includeAPIKeys: Bool) -> Bool {
        switch ConfigExporter.export(snapshot, includeAPIKeys: includeAPIKeys) {
        case .success:
            showToast(
                .init(
                    kind: .success,
                    text: "已复制到系统剪贴板",
                    detail: "请打开键盘 → ⚙️ → 导入配置"
                )
            )
            return true
        case .failure(let message):
            showToast(.init(kind: .failure, text: "配置导出失败", detail: message))
            return false
        }
    }

    // MARK: - 引导与偏好

    /// 标记引导完成。
    func completeOnboarding() {
        hasCompletedOnboarding = true
        preferences.set(true, forKey: Keys.onboarding)
    }

    /// 重新观看引导。
    func restartOnboarding() {
        hasCompletedOnboarding = false
        preferences.set(false, forKey: Keys.onboarding)
    }

    private func persistAppearance() {
        preferences.set(appearanceMode.rawValue, forKey: Keys.appearance)
    }

    // MARK: - Toast

    /// 弹出一条提示。
    func showToast(_ message: ToastMessage) {
        toast = message
    }

    /// 关闭当前提示。
    func dismissToast() {
        toast = nil
    }

    /// 刷新短语数量缓存。
    func refreshPhraseCount() {
        phraseCount = PhraseStore.count
    }
}

// MARK: - 扩展安装检测

/// 键盘扩展是否"已装进设备"的启发式探测。
///
/// 说明：宿主 App 无法直接查询"设置里是否已添加本键盘"（系统不提供该 API）。
/// 这里只能判断扩展二进制是否随 App 一起装进来了。
enum ExtensionDetector {

    /// 扩展 bundle 是否存在于主 App 的 PlugIns 目录。
    static func isInstalled() -> Bool {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else { return false }
        let candidate = pluginsURL.appendingPathComponent(AppInfo.extensionBundleName)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// 探测的候选路径（用于诊断页展示）。
    static func candidatePath() -> String {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else { return "（无法读取 PlugIns 目录）" }
        return pluginsURL.appendingPathComponent(AppInfo.extensionBundleName).path
    }
}
