//
//  ThemeStore.swift
//  墨语（Moyu）· 共享层 · Theme
//
//  模块职责：
//      主题与自定义小形象的持久化。把「当前主题 id / 自定义形象 PNG / 形象显示名」
//      三份状态读写到 `SharedStore`（App 与键盘扩展共用的三级存储），并对外提供
//      「当前生效的 AppTheme」（找不到就回退默认主题）。
//
//  依赖：
//      Foundation；
//      `SharedStore`（`ios/Shared/Storage/SharedStore.swift`）与 `SharedStoreKey.theme*`；
//      `AppTheme`（`ios/Shared/Theme/AppTheme.swift`）。
//
//  使用方：
//      宿主 App `ios/AIKeyboard/Settings/ThemeSettingsView.swift`（选主题 / 导入形象）；
//      键盘扩展 `ios/AIKeyboardExtension/Views/KMThemePicker.swift` 与
//      `ExtensionSettingsSheet`（只能选预设 + 选已导入形象，导入要在宿主 App）；
//      键盘根视图读取 `ThemeStore.shared.currentTheme` 决定 4 处主色。
//
//  存储降级（design/05 §2.2，非 bug）：
//      无 App Group 时 `SharedStore` 自动降级到各自的 `UserDefaults.standard`，
//      宿主 App 选的主题键盘扩展读不到 —— 这与心跳键的降级行为一致：
//      扩展用自己的 standard 存一份，用户在键盘内设置页也能单独选主题。
//      将来开启 App Groups 自动打通，本文件零改动。
//
//  threads：所有方法都是同步的轻量 `UserDefaults` 读写，内部串行靠 UserDefaults 自身线程安全；
//      标注 `@unchecked Sendable` 以便在任意 Task 上下文里直接读取当前主题。
//

import Foundation

/// 主题与自定义形象的持久化。
///
/// ```swift
/// // 读当前主题（键盘每次渲染都会调，开销极小）
/// let theme = ThemeStore.shared.currentTheme
/// // 换主题
/// ThemeStore.shared.currentThemeID = AppTheme.Preset.coral.rawValue
/// // 导入自定义形象后自动切到 custom
/// ThemeStore.shared.customMascotData = pngData
/// ThemeStore.shared.customMascotName = "我的鲸鱼"
/// ThemeStore.shared.currentThemeID = AppTheme.customID
/// ```
public final class ThemeStore: @unchecked Sendable {

    /// 全局共享实例。所有读写都直接落到 `SharedStore.shared`，无内存缓存
    /// （保证键盘扩展与宿主 App 在同一进程外读到的是最新值）。
    public static let shared = ThemeStore()

    /// 存储后端（默认 `SharedStore.shared`，测试可注入内存实例）。
    private let store: SharedStore

    /// 构造。
    ///
    /// - Parameter store: 存储后端，默认用共享实例；单元测试/预览可传 `SharedStore(forceMemory: true)`。
    public init(store: SharedStore = .shared) {
        self.store = store
    }

    // MARK: - 当前主题

    /// 当前主题 id。
    ///
    /// 取值：`AppTheme.Preset.rawValue`（`"ink"`/`"coral"`/`"indigo"`/`"violet"`/`"sky"`/`"pine"`）
    /// 或 `AppTheme.customID`（`"custom"`）。**读写都是纯字符串**，非法值不会被纠正，
    /// 由 `currentTheme` 在读取时回退默认主题（这样用户手动写坏配置也不会白屏）。
    public var currentThemeID: String {
        get {
            store.string(forKey: SharedStoreKey.themeCurrent) ?? AppTheme.default.id
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                store.remove(forKey: SharedStoreKey.themeCurrent)
            } else {
                store.set(trimmed, forKey: SharedStoreKey.themeCurrent)
            }
        }
    }

    /// 当前生效的主题（找不到就回退 `AppTheme.default`）。
    ///
    /// 三种情况：
    /// 1. id 命中 6 个预设之一 → 返回该预设主题；
    /// 2. `id == "custom"` 且已导入形象 → 返回配色沿用默认主题、名称用自定义名的主题；
    /// 3. 其余（id 非法 / custom 但没导入形象 / 从未设置过）→ 返回 `AppTheme.default`。
    public var currentTheme: AppTheme {
        let id = currentThemeID
        if id == AppTheme.customID {
            guard hasCustomMascot else { return AppTheme.default }
            return AppTheme.custom(mascotName: customMascotName)
        }
        return AppTheme.preset(withID: id) ?? AppTheme.default
    }

    /// 是否为「用户自己导入形象」的主题（`currentThemeID == "custom"` 且有形象数据）。
    ///
    /// 键盘侧用它决定右下角小形象节点显示图片还是几何符号。
    public var isUsingCustomMascot: Bool {
        currentThemeID == AppTheme.customID && hasCustomMascot
    }

    // MARK: - 自定义形象

    /// 自定义形象（512×512 PNG 原始 `Data`）。
    ///
    /// 导入时已由宿主 App 裁成正方形并缩放到 512×512（design/05 §4.2），
    /// 这里只做原样存取，不做二次处理。设为 `nil` 等价于删除。
    public var customMascotData: Data? {
        get {
            store.data(forKey: SharedStoreKey.themeCustomMascot)
        }
        set {
            if let data = newValue, !data.isEmpty {
                store.setData(data, forKey: SharedStoreKey.themeCustomMascot)
            } else {
                store.remove(forKey: SharedStoreKey.themeCustomMascot)
            }
        }
    }

    /// 是否已导入过自定义形象。
    public var hasCustomMascot: Bool {
        guard let data = customMascotData else { return false }
        return !data.isEmpty
    }

    /// 自定义形象的显示名（用户可改，默认「我的形象」）。
    ///
    /// 空串或全空白一律归一成「我的形象」，避免设置页出现空标题。
    public var customMascotName: String {
        get {
            let raw = store.string(forKey: SharedStoreKey.themeCustomMascotName) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? ThemeStore.defaultMascotName : trimmed
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                store.remove(forKey: SharedStoreKey.themeCustomMascotName)
            } else {
                store.set(trimmed, forKey: SharedStoreKey.themeCustomMascotName)
            }
        }
    }

    /// 自定义形象的默认显示名。
    public static let defaultMascotName = "我的形象"

    /// 清除自定义形象（数据 + 名字），并把当前主题切回默认。
    ///
    /// 用户点「关闭小形象」或「删除我的形象」时调用；不会动 6 个预设主题的选择记录之外的东西。
    public func clearCustomMascot() {
        store.remove(forKey: SharedStoreKey.themeCustomMascot)
        store.remove(forKey: SharedStoreKey.themeCustomMascotName)
        if currentThemeID == AppTheme.customID {
            currentThemeID = AppTheme.default.id
        }
    }

    // MARK: - 其它

    /// 键盘右下角是否显示小形象（默认 `true`）。
    ///
    /// 与「用哪套主题」相互独立：关掉后空格键会变宽占满整行（design/05 §3.4），
    /// 但主题配色与已导入的形象数据都保留，重新打开即可恢复。
    /// 宿主 App 的「主题与小形象」设置页与键盘内设置页读写同一个键
    /// （`SharedStoreKey.themeShowsMascot`）。
    public var showsMascot: Bool {
        get {
            store.bool(forKey: SharedStoreKey.themeShowsMascot, default: true)
        }
        set {
            store.setBool(newValue, forKey: SharedStoreKey.themeShowsMascot)
        }
    }

    /// 全部可选主题（6 个预设；不含自定义形象主题）。
    ///
    /// 设置页 2 列网格与键盘内 6 个色点选择器都用它，顺序固定。
    public var availableThemes: [AppTheme] {
        AppTheme.allPresets
    }

    /// 把主题重置为默认（靛蓝），但**不清除**已导入的形象数据。
    public func resetToDefault() {
        currentThemeID = AppTheme.default.id
    }
}
