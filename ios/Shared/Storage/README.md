# ios/Shared/Storage — 存储层说明

> 模块职责：App 与键盘扩展的**配置 / API Key / 自定义内容**持久化。
> 使用方：宿主 App（`ios/AIKeyboard/`）、键盘扩展（`ios/AIKeyboardExtension/`）、
> `ios/Shared/Prompts/`（自定义模板）、`ios/Shared/IMECore/`（自定义短语）。
> 依赖：`Foundation` + `UIKit`（仅 `UIPasteboard`；**全目录不出现** `UIApplication.shared`）。

本目录四个文件：

| 文件 | 公开类型 | 职责 |
| --- | --- | --- |
| `SharedStore.swift` | `SharedStore` / `SharedStore.Backing` / `SharedStoreKey` | 三级降级存储门面（App Group → standard → memory） |
| `ConfigStore.swift` | `ConfigStoring` / `ConfigStore` / `InMemoryConfigStore` | `ConfigSnapshot` 的 JSON 持久化 + 版本迁移 + 默认值工厂 |
| `KeychainStore.swift` | `KeychainStore` / `KeychainError` | API Key 的 Keychain 读写（`kSecClassGenericPassword`） |
| `PasteboardBridge.swift` | `PasteboardBridge` / `ExportPayload` / `PasteboardBridgeError` | 命名剪贴板搬运配置（magic + 版本 + 校验和） |

---

## 1. 三级存储策略（`SharedStore`）

`SharedStore` 按顺序尝试三种底层容器，**构造时一次性决定**，之后 `backing` 不再变化：

| 级别 | `backing` | 底层容器 | 是否跨进程共享 | 何时命中 |
| --- | --- | --- | --- | --- |
| ① | `.appGroup` | `UserDefaults(suiteName: "group.com.moyu.keyboard")` | ✅ App ↔ 扩展共享 | 两个 target 的 entitlements 都配置了同一个 App Group，且写-读-删探测通过 |
| ② | `.standard` | `UserDefaults.standard` | ❌ App 与扩展**各自独立** | 免费 Apple ID 签名 / 未配 App Group（**现实中的常态**） |
| ③ | `.memory` | 临时 suite 的 `UserDefaults`，进程内有效 | ❌ 不落盘 | `UserDefaults(suiteName:)` 与 `.standard` 都不可用的极端情况，或 `forceMemory: true`（测试） |

判定方式：对 `UserDefaults(suiteName:)` 做一次 **写 → 读 → 删** 探测
（`SharedStore.probe(_:)`，探测键 `moyu.probe.<UUID>`）。iOS 的 `UserDefaults(suiteName:)`
在未配置 App Group 时**仍会返回对象**，但写入后立刻读取会失败，所以必须用探测而不是判空。

对外可读状态：

```swift
SharedStore.shared.backing                     // .appGroup / .standard / .memory
SharedStore.shared.isAppGroupAvailable         // 只有 ① 为 true
SharedStore.shared.storageStatusDescription    // 直接可显示给用户的中文说明
```

### 键名前缀规则

| `backing` | 实际写入的键 | 说明 |
| --- | --- | --- |
| `.appGroup` | 原样（`moyu.config.snapshot`） | 与文档、旧版本一致 |
| `.standard` / `.memory` | `moyu.shared.` + 原键 | 避免与宿主 App 自己的偏好键同名互踩 |

`SharedStoreKey` 集中了所有键名常量（`configSnapshot` / `customPrompts` / `phrases` /
`clipboardHistoryEnabled` / `currentTone` / `targetLanguage` / `lastChatProviderID` /
`hasCompletedOnboarding`），业务代码不要手写字符串。

### 免费账号（无 App Group）的现实约束

> **免费 Apple ID 个人团队签名无法为键盘扩展配置 App Group**（见 `docs/01` §6）。
> 此时 `isAppGroupAvailable == false`，App 与键盘扩展**各自持有独立的 `UserDefaults`**：
> 在 App 里改的默认服务商、语气、自定义提示词，**不会自动出现在键盘里**；
> API Key 存在各自的 Keychain 里，同样不互通。

代码层不需要特判——所有读写都走 `SharedStore`，付费账号补上 entitlements 后自动升级到 ①，
**无需改一行代码**。需要互通时由 `PasteboardBridge` 承担搬运（见第 3 节）。

---

## 2. API Key 的存储（`KeychainStore`）

```swift
public final class KeychainStore: @unchecked Sendable {
    public static let shared: KeychainStore
    public let service: String                                   // 默认 "com.moyu.apikey"
    public init(service: String = "com.moyu.apikey")

    public var isAvailable: Bool                                  // 写-删探测
    public func apiKey(for providerID: String) -> String?
    public func hasAPIKey(for providerID: String) -> Bool
    public func setAPIKey(_ apiKey: String, for providerID: String) throws
    public func deleteAPIKey(for providerID: String) throws
    public func deleteAllAPIKeys()
    public func providerIDsWithKeys() -> [String]
}
```

- 条目类型 `kSecClassGenericPassword`，`kSecAttrService = service`，`kSecAttrAccount = providerID`；
- 可访问性 `kSecAttrAccessibleAfterFirstUnlock`——**键盘扩展可用**：设备首次解锁后即可读，
  扩展在锁屏状态下不一定能读（键盘在锁屏场景本就不联网，可接受）；
- `setAPIKey("")` 等价于删除，避免 Keychain 里留空串；
- 跨进程共享 Keychain 条目需要 **Keychain Sharing** 能力（同一 access group）；
  免费账号下 App 与扩展的 Keychain 也是分开的，用户需在两侧各填一次，或用剪贴板导出（含风险提示）。
- `KeychainError` 已带中文 `errorDescription` / `recoverySuggestion`
  （`errSecMissingEntitlement` → 提示去 Xcode 添加 Keychain Sharing）。

**API Key 永不出现在 `ConfigSnapshot` 的 JSON 里**：`AIProviderConfig.apiKeyRef` 是计算属性
（返回 `id`），不参与 `Codable`。导出配置默认也不含 Key。

---

## 3. 配置搬运（无 App Group 时的用户操作路径）

`PasteboardBridge` 用命名剪贴板 `com.moyu.config`（`UIPasteboard.Name("com.moyu.config")`）
传递一段四行文本：

```
MOYU_CONFIG_V1
envelope:1 snapshot:2
fnv1a64:9f3c1a7e5b2d0044
{"version":2,"providers":[…],"apiKeys":null,…}
```

| 行 | 内容 | 用途 |
| --- | --- | --- |
| 1 | `MOYU_CONFIG_V1` | 魔数，识别「这段文本是墨语配置」 |
| 2 | `envelope:<信封版本> snapshot:<配置结构版本>` | 信封格式与 `ConfigSnapshot.currentVersion` 各自独立演进 |
| 3 | `fnv1a64:<16 位小写十六进制>` | 只覆盖第 4 行 JSON 的 FNV-1a 64 校验和，检测复制截断 |
| 4 | `ExportPayload` JSON（`.sortedKeys`） | `{"snapshot":{…},"apiKeys":{…}?}` |

### 用户操作路径（App → 键盘）

1. 打开宿主 App → **设置 › 配置迁移 › 导出配置**；
2. 若是首次使用，先在各服务商卡片里填 API Key（可选：勾选「同时导出 API Key」）；
3. 切到任意输入框 → 调起墨语键盘 → 点候选栏 ⚙️ → **导入配置**；
4. 键盘内提示「已导入 N 项服务商配置，M 个 API Key」。

> 键盘里导入后**必须重新填一次 API Key**（除非导出时勾选了「同时导出 API Key」）；
> 勾选后 Key 会**以明文**写进剪贴板，UI 必须弹二次确认。

### 导入校验顺序

`decodeEnvelope(_:)` 依次校验，任一失败抛 `PasteboardBridgeError`（全部带中文提示）：

1. 空载荷 → `.emptyPayload`
2. 首行不是 `MOYU_CONFIG_V1` → `.wrongMagic`（提示「剪贴板里不是墨语配置」）
3. 信封版本不认识 → `.unsupportedVersion("…")`（提示「请升级到最新版」）
4. 行结构/JSON 结构坏 → `.malformed("…")`
5. 校验和不符 → `.checksumMismatch`（提示「内容可能复制不完整，请重新导出」）

`pasteboardString()` 优先读命名剪贴板；命名剪贴板为空时回退读 `UIPasteboard.general`，
**但要求内容以 magic 开头**才接受（避免把用户随便复制的文本当成配置）。

### API Key 导出的安全边界

- `includeAPIKeys: false`（默认）：`apiKeys` 字段为 `null`，剪贴板里**没有**明文 Key；
- `includeAPIKeys: true`：`apiKeys: { "<providerID>": "<key>" }` 明文写入。
  **不做加密**——剪贴板内容任何 App 都能读，加密只是把明文换成同样能被读走的密钥。
  风险必须在 UI 上说清，并建议导出后尽快导入、随后清空剪贴板；
- `ExportPayload.applyAPIKeys() -> Int` 把 payload 里的 Key 写进本机 Keychain，返回写入条数。

---

## 4. 配置版本与迁移规则（`ConfigStore`）

`ConfigSnapshot.currentVersion == 2`。迁移函数 `ConfigStore.migrate(_:)` 在 `load()`
解码成功后自动执行，**只改内存、不隐式写盘**；下一次 `save(_:)` 才会落盘为 v2。

### v1 → v2（新增 `imageProviderID`）

v1 的快照没有「生图服务商」概念（生图与文本对话共用同一个 Provider）。迁移规则：

| 字段 | v1 缺失/异常时 | 迁移后取值 |
| --- | --- | --- |
| `imageProviderID` | 字段不存在 → 解码为 `nil` | 优先取 `providers` 里第一个 `supportsImage` 的服务商 id；都没有则用 `PresetProviders.defaultImagePreset?.id`（`preset-seedream`） |
| `defaultProviderID` | `nil` 或指向的服务商 `!supportsChat` | 换成 `providers` 里第一个 `supportsChat` 的服务商 id |
| `providers` | 空数组（极端损坏） | 灌入 `ConfigSnapshot.presetOnly().providers` |
| `replyCount` | 越界（老版本无 clamp） | 收敛到 `1...5` |
| `defaultTone` | 空串 | `"自然"` |
| `imageSize` | 空串 | `"1024x1024"` |
| `version` | 任意 | 归一为 `ConfigSnapshot.currentVersion` |

**向后兼容**：`ConfigSnapshot` 的所有字段都用 `decodeIfPresent` + 默认值解码，
所以 v1 的 JSON 能被 v2 的 `init(from:)` 直接读懂；`save(_:)` 会把 `version` 归一后再写，
保证磁盘上永远不会出现 `version: 1`。

### 其他重要行为

- `load()` **永不抛错**：没数据、JSON 坏、结构不认识，一律返回 `ConfigSnapshot.defaultValue()`，
  避免键盘因为一段坏数据整体不可用；
- `resetToDefault()` 覆盖磁盘为出厂默认；`resetToPresetOnly()` 只清用户自建服务商，
  保留 `defaultTone` / `replyCount` / `enableClipboardHistory` / `enableLearning` / `imageSize`；
- `hasStoredSnapshot` 用于「首次启动」判定（不要用 `load()` 的返回值判断）。

---

## 5. 宿主 App / 键盘扩展的接入方式

```swift
// App 与扩展都用同一个构造（键必须一致，扩展不要另起键名）
let configStore = ConfigStore()
var snapshot = configStore.load()
snapshot.defaultTone = "正式"
configStore.save(snapshot)

// 存储状态展示（设置页「存储状态」一行）
Text(SharedStore.shared.storageStatusDescription)

// 导出 / 导入
try PasteboardBridge.export(snapshot, includeAPIKeys: false)
if let imported = PasteboardBridge.importSnapshot() {
    configStore.save(imported)
}
```

> 键盘扩展里**不要**创建自己的 `ConfigStore(key:)`，否则 App 与扩展会读写两份不同的数据。
