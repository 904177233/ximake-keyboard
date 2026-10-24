# 墨语 · 宿主 App（ios/AIKeyboard）

> 模块职责：墨语 iOS AI 输入法的宿主 App，负责**引导、配置、试用、诊断**四件事。
> 键盘本体在 `ios/AIKeyboardExtension/`，共享契约在 `ios/Shared/`，本目录**只写 App 层**。

- 语言 / 框架：Swift 5.9 + SwiftUI，最低 **iOS 16.0**
- 目录：`ios/AIKeyboard/`（51 个 `.swift` / 11,538 行 + 本 README + `selfcheck.py`）
- 全中文 UI；所有颜色、字号、间距、圆角、动效**只从 `Theme` 取**，禁止硬编码
- 无第三方依赖，无网络图片，无统计 SDK

---

## 1. 页面清单（12 个主页面 + 支撑页）

| # | 页面 | 文件 | 入口 / 导航方式 |
|---|------|------|----------------|
| 1 | 引导（5 步） | `Onboarding/OnboardingView.swift` + `OnboardingModels.swift` | `RootView` 首启分支，全屏无 Tab |
| 2 | 主 Tab 容器 | `Main/MainTabView.swift` | `RootView` 常规分支 |
| 3 | 键盘主页 | `Main/KeyboardHomeView.swift` | Tab 1「键盘」 |
| 4 | AI 试验场 | `Playground/PlaygroundView.swift`（+ `PlaygroundEngine` / `PlaygroundParameterSection` / `PlaygroundActionSection`） | Tab 2「AI」 |
| 5 | 设置主页 | `Main/SettingsView.swift` | Tab 3「设置」 |
| 6 | AI 服务列表 | `Settings/ProviderListView.swift` | 设置 › AI 服务 / 生图服务商；键盘主页 › 服务商 |
| 7 | 服务商编辑 | `Settings/ProviderEditorView.swift`（+ `ProviderAdvancedEditor` / `TestConnectionView`） | Sheet（列表「+」、引导第 4 步） |
| 8 | Prompt 模板库 | `Settings/PromptLibraryView.swift` | 设置 › Prompt 模板 |
| 9 | Prompt 编辑 | `Settings/PromptEditorView.swift` | Sheet（模板库「+」/「复制为自定义」） |
| 10 | 同步到键盘 | `Settings/ConfigTransferView.swift`（尾附 `PasteboardSyncSection` 兼容壳） | 设置 › 同步到键盘 |
| 11 | 安装与续签指南 | `Guide/InstallGuideView.swift` | 设置 › 安装与续签；键盘主页；引导第 5 步；关于页 |
| 12 | 诊断 | `Guide/DiagnosticsView.swift`（+ `DiagnosticsChecklist` / `DiagnosticsFormat`） | 设置 › 诊断；键盘主页；关于页 |
| 13 | 关于 | `Settings/AboutView.swift` | 设置 › 关于 |
| 14 | 外观与语音偏好 | `Settings/AppearanceView.swift` | 设置 › 语气与外观；键盘主页 |
| 15 | 隐私说明 | `Settings/PrivacyView.swift` | 设置 › 隐私说明 |

> 编号 13–15 是设置二级页，设计规范里归入「结构页」，不算独立一级页面。

### 导航结构

```
AIKeyboardApp (@main)
└─ WindowGroup → RootView
   ├─ hasCompletedOnboarding == false → OnboardingView（全屏，5 步，TAB 不可用）
   │   ├─ step4「去配置」→ navigationDestination → ProviderEditorView
   │   ├─ step5「看安装指南」→ navigationDestination → InstallGuideView
   │   ├─ step3「查看图示」→ sheet → SettingPathGuideSheet（纯 SwiftUI 绘制的设置路径图）
   │   └─ 完成 → appState.completeOnboarding() → RootView 切换
   └─ hasCompletedOnboarding == true → MainTabView
        ├─ Tab 1 键盘  NavigationStack → KeyboardHomeView
        │     ├─ → InstallGuideView() / InstallGuideView(initialStep: 3)
        │     ├─ → ProviderListView() / ProviderListView(showImageProviders: true)
        │     ├─ → AppearanceView()
        │     ├─ → InstallGuideView() / DiagnosticsView()
        │     └─ sheet → KeyboardStatusHelpSheet（状态判定说明 + 手动确认三步）
        ├─ Tab 2 AI    NavigationStack → PlaygroundView（无上层 push）
        └─ Tab 3 设置  NavigationStack → SettingsView
              ├─ AI  组：ProviderListView / ProviderListView(showImageProviders:) /
              │         AppearanceView / PromptLibraryView
              ├─ 键盘组：4 行只读占位（见 §6）
              ├─ 隐私组：PrivacyView
              ├─ 同步组：ConfigTransferView
              ├─ 支持组：InstallGuideView / DiagnosticsView / AboutView
              └─ 危险组：重置服务商 / 重新观看引导（Alert 二次确认）
```

- 一级页用 `.large` 大标题，二级页 `.inline`。
- `ProviderEditorView`、`PromptEditorView` 用 **Sheet**（`.presentationDetents([.large])`），采用 `NavigationStack` + `.toolbar` 的「取消 / 保存」，**不用** `SheetHeader`（那是给键盘内面板的）。
- 状态提示统一走 `AppState.toast` + `.toastOverlay()`，挂在 `AIKeyboardApp` 的根视图上，全局只有一个。

---

## 2. 目录结构与职责

```
ios/AIKeyboard/
├─ AIKeyboardApp 相关
│  ├─ App/AIKeyboardApp.swift      @main；注入 AppState；preferredColorScheme / tint / dynamicType 限幅 / toastOverlay
│  ├─ App/RootView.swift           首启分流（Onboarding ↔ MainTabView）
│  ├─ App/AppState.swift           @MainActor ObservableObject：唯一状态中枢（见 §3）
│  └─ App/AppModels.swift          MainTab / AppearanceMode / ToneOption / ImageSizeOption / TargetLanguageOption /
│                                  ToastMessage / ProviderKindHint / AppInfo / KeyboardSetupState
├─ Components/ (20)
│  ├─ SurfaceCard / SectionHeader / ListGroup / SettingsRow(+IconSpec,StatusDot,RowDivider,StatusDotView)
│  ├─ SegmentedTabs / PillChip / PrimaryButton(+SecondaryButton) / IconGlyph(+FeatureGlyph)
│  ├─ EmptyState / ErrorBanner / FormFieldRow / StepCard(+StepConnector)
│  ├─ StreamingText / AIResultCard(+AIErrorViewData,ImageProgress,ImageResultViewData,ProgressRing) / ProgressDots
│  ├─ ProviderRow(+ConnectionStatus) / SheetHeader / ToneSelector / GlassSurface / Haptics / ToastView
├─ Onboarding/  OnboardingModels.swift · OnboardingView.swift
├─ Main/        MainTabView.swift · KeyboardHomeView.swift · SettingsView.swift
├─ Settings/    ProviderListView · ProviderEditorView · ProviderAdvancedEditor · TestConnectionView
│               PromptLibraryView · PromptEditorView · ConfigTransferView · AppearanceView · PrivacyView · AboutView
├─ Playground/  PlaygroundView · PlaygroundEngine · PlaygroundParameterSection · PlaygroundActionSection
├─ Guide/       InstallGuideView · DiagnosticsView · DiagnosticsChecklist · DiagnosticsFormat
├─ Support/     AppMetrics.swift · SharedBridge.swift · SignatureClock.swift · ViewCompat.swift
├─ selfcheck.py 自写静态自查脚本（Python 3，无依赖）
└─ README.md
```

按目录行数：App 4 文件 / 800 行 · Components 20 / 3,421 · Guide 4 / 1,254 · Main 3 / 840 · Onboarding 2 / 458 · Playground 4 / 990 · Settings 10 / 2,988 · Support 4 / 787。**单文件最大 `Components/AIResultCard.swift` 562 行，全部 ≤ 600 行**。

---

## 3. `AppState`：App 与界面的唯一状态中枢

`ios/AIKeyboard/App/AppState.swift`，`@MainActor final class AppState: ObservableObject`。

- **唯一的 `ConfigStore` 实例化点**（`makeDefaultConfigStore() -> ConfigStoring`），**没有第二份配置真相**；`init(configStore:)` 允许注入 `InMemoryConfigStore` 做 Preview。
- 发布状态：`snapshot: ConfigSnapshot`（`private(set)`，改动一律走 `updateSnapshot { inout }`，内部强制 `version = ConfigSnapshot.currentVersion` 后 `save`）、`selectedTab`、`hasCompletedOnboarding`、`appearanceMode`（didSet 持久化）、`toast`、`dictionaryInfo`、`phraseCount`、`isExtensionInstalled`、`isKeychainAvailable`、`extensionLastActiveAt`、`extensionLastNetworkOKAt`。
- 派生：`providers` / `chatProviders` / `imageProviders` / `defaultChatProvider` / `imageProvider` / `isChatReady` / `isImageReady` / `hasDefaultChatAPIKey` / `hasImageAPIKey` / `isReadyForAI` / `currentTone` / `keyboardSetupState` / `keyboardStatusDetail`。
- 写操作：`upsertProvider` / `deleteProvider`（连带删 Keychain Key 并修正两个默认 ID）/ `setDefaultChatProvider` / `setDefaultImageProvider`（**仅生图服务商被选为对话服务商时拒绝并 Toast**）/ `setClipboardHistoryEnabled` / `setLearningEnabled` / `setDefaultTone` / `setReplyCount`(clamp 1...5) / `setImageSize` / `resetToPresetOnly` / `apiKey(for:)` / `saveAPIKey` / `deleteAPIKey` / `exportConfigToKeyboard(includeAPIKeys:)` / `completeOnboarding` / `restartOnboarding` / `showToast` / `dismissToast` / `refreshPhraseCount`。
- 持久化的两个 App 私有偏好键：`moyu.host.hasCompletedOnboarding`、`moyu.host.appearanceMode`（写在 `SharedStore.shared.defaults` 上；无 App Group 时 SharedStore 会给自己的键加前缀，这两个裸键与之不冲突）。

---

## 4. 与 Shared 层的对接点

### 4.1 集成缝：`Support/SharedBridge.swift`

App 层**不直接**散落调用 Shared API，所有跨层细节收敛在这一个文件（348 行）：

| 封装 | 作用 | 转调 |
|------|------|------|
| `PromptCatalog` | 内置/自定义模板 + 渲染成 `[ChatMessage]` | `PromptLibrary.builtIn` / `.templates(feature:)` / `.template(id:)` / `.loadCustom()` / `.saveCustom()` / `.render(...)` / `.upsertCustom` / `.removeCustom` |
| `PhraseStore` | 快捷短语增删查计数 | `PhraseLibrary(store: SharedStore.shared)` 的 `.items` / `.upsert(_:)` / `.remove(id:)` |
| `DictionaryInfo` | 词库版本与词条数（诊断页、键盘主页） | `PinyinDictionary.bundled()` 的 `.version` / `.wordCount` |
| `ConfigExporter` | 配置导出/导入 | `PasteboardBridge.export(_:includeAPIKeys:)` / `.importSnapshot()` / `.hasImportableContent` / `SharedStore.isAppGroupAvailable` |
| `ConnectivityProbe` | 网络探针 + 「测试连接」最小流式请求 + 生图 | `URLSession` + `AIClientFactory.makeLLM(config:apiKey:)` / `.makeImage(...)` |
| `ErrorPresenter` | `AIError` → 中文主文案 + 建议 | `AIError.errorDescription` / `.recoverySuggestion` + `NSURLErrorDomain` 分支 |
| `ExtensionTelemetry` | App ↔ 扩展的「心跳」约定（见 §5） | `SharedStore.shared.double(forKey:default:)` |

### 4.2 依赖的 Shared 符号（逐个已核对存在）

- **Theme**：`Theme.color`（40 个文件引用）、`AppColor`/`AppFont`/`AppMetrics` 全部转发自 `Theme`；实际用到 `surface/surfaceElevated/surfaceGrouped/textPrimary/textSecondary/textTertiary/textPlaceholder/textOnAccent/accent/accentSoft/accentPressed/success/successSoft/warning/warningSoft/danger/dangerSoft/separator/separatorOpaque/chipBackground/chipBackgroundPressed/chipBorder/chipText/overlayScrim`；`fontLargeTitle/fontTitle/fontHeadline/fontBody/fontCaption/fontFootnote/fontButton/fontChip/fontResult/fontCandidate/fontMonoDigit`；`Spacing.*`；`Radius.*`；`Motion.fast/normal/spring/fastAnimation/normalAnimation/streamCursorBlink/toastDuration`；`Shadow.card/chip/glass`；`MaterialToken.strokeWidth`；`Sizing.aiChipHeight/resultActionHeight`。
- **Storage**：`ConfigStore` / `InMemoryConfigStore`（仅 Preview 注入）/ `ConfigStoring` / `SharedStore`(+`SharedStoreKey`/`isAppGroupAvailable`/`storageStatusDescription`/`defaults`) / `KeychainStore` / `PasteboardBridge`(+`ExportPayload`)。
- **Models**：`ConfigSnapshot` / `AIProviderConfig` / `ModelRef` / `ProviderKind` / `PresetProviders`(+`Preset`) / `AIFeature`。
- **Prompts**：`PromptTemplate` / `PromptLibrary`。
- **Networking**：`LLMClient` / `ImageGenerating` / `AIClientFactory` / `AIError` / `ChatMessage` / `ChatRequest` / `ChatDelta` / `ChatResult` / `TokenUsage` / `ImageRequest` / `GeneratedImage`。
- **IMECore**：`PinyinDictionary`（`bundled()` / `version` / `wordCount`）、`PhraseLibrary`（`init(store:)` / `items` / `upsert(_:)` / `remove(id:)`）、`PhraseItem`（`init(key:text:)` / `init(id:key:text:isPinned:)`）。

> **SHARED-DEP 缺失清单：空。** 截至本文件写入时，上述符号全部已在 `ios/Shared/` 落盘并通过签名核对（IMECore 的 `PinyinDictionary`/`PhraseLibrary` 最后补齐）。
> 唯一需要 Shared 侧配合的**非符号约定**是 §5 的心跳键名。

---

## 5. App ↔ 键盘扩展的约定（跨 target，非 Shared API）

免费 Apple ID 没有 App Group，App 与扩展各自的 `UserDefaults` 不共享，因此「键盘是否已添加 / 完全访问是否开启」**无法被 App 直接查询**。本模块采用**扩展写心跳、App 读心跳**的启发式：

| 键（`SharedStore`） | 写入方 | 语义 |
|--------------------|--------|------|
| `moyu.ext.lastActiveAt` | 扩展（键盘每次被唤起） | 最近一次键盘被使用的时间戳（`Double`） |
| `moyu.ext.lastNetworkOKAt` | 扩展（AI 请求成功一次） | 最近一次「联网成功」的时间戳 → 反推完全访问已开启 |

- 读取端：`Support/SharedBridge.swift` 的 `enum ExtensionTelemetry`（`lastActiveAt()` / `lastNetworkOKAt()` / `isRecentlyActive`(24h) / `hasRecentNetworkSuccess` / `relativeDescription(_:)`）。
- 消费端：`AppState.keyboardSetupState`（`.ready` / `.partial` / `.notConfigured`）、`KeyboardHomeView` 状态卡、`DiagnosticsView` 的 `extension` 与 `fullAccess` 两项。
- **不确定时一律说「可能未开启」并给「如何确认」入口**，绝不假装确定（`KeyboardStatusHelpSheet` 解释为什么 iOS 不允许查询）。

> **当前状态（需 keyboard-ui / ime-core 侧配合）**：截至本文件写入时，`ios/AIKeyboardExtension/` **尚未**写入这两个键（全目录 grep `moyu.ext.` 无结果）。因此 App 侧的状态判定会一直走到「还没有检测到使用记录 / 可能未开启」分支——这是**有意设计的安全降级**（不确定就说不确定，并给「如何确认」入口），不会崩溃也不会误报。
> 若键名要改，只需改 `Support/SharedBridge.swift` 的 `ExtensionTelemetry` 一处；若保持键名，扩展侧只需在 `keyboardDidAppear` / AI 请求成功回调里各写一次 `Double` 时间戳即可。

---

## 6. 未实现 / 占位项（明确记录，避免误判为已完成）

| 项 | 现状 | 位置 |
|----|------|------|
| 快捷短语管理页 | **未实现**。只有 `PhraseStore.add`（试验场「保存为短语」）与 `PhraseStore.count`（键盘主页显示条数），没有列表 / 编辑 / 删除 UI；键盘主页「快捷短语」行当前不可点击 | `App/AppState.swift`、`Playground/PlaygroundActionSection.swift` |
| 保存图片到相册 | **未实现**。生图结果只提供「复制图片」（写 `UIPasteboard.general.image`）；未申请 `NSPhotoLibraryAddUsageDescription`，故不做保存 | `Components/AIResultCard.swift` |
| 键盘组 4 个开关 | **只读占位**。`键盘布局`(26 键) / `候选字号`(标准) / `按键音`(关闭) / `振动反馈`(开启) 均为 `.value(...)` 纯展示，未接持久化，也未与扩展联动 | `Main/SettingsView.swift` `keyboardGroup` |
| 清除本地数据 | **部分实现**。`PrivacyView.clearLocalData()` 目前只把「剪贴板历史 / 本地学习」两个开关置 false 并 Toast，**没有真删**短语与词频数据（未调 `SharedStore.removeAllSharedValues()`） | `Settings/PrivacyView.swift` |
| 反馈邮箱 | 占位常量 `moyu.feedback@example.com`，仓库内可改 | `Settings/AboutView.swift:21` |
| 签名剩余天数 | 按「首次运行日期 + 7 天」估算，不是真实签名信息（iOS 不提供该接口），文案已注明 | `Support/SignatureClock.swift` |
| 键盘布局 / 候选字号 | 设计规范提到但产品未定稿，App 侧不提供可写入口 | 同「键盘组 4 个开关」 |

**契约外自造组件**（`design/组件库.md` 未定义，按需补，已在此备案）：
- `Components/FormFieldRow.swift`：表单字段行（标题 + 必填星 + 提示 + 内容槽）—— ProviderEditor / PromptEditor 共用。
- `Support/ViewCompat.swift`：`scrollContentBackgroundHiddenCompat()`（iOS 16 兼容包装，避免两处 private 扩展重复声明）。
- `Support/SignatureClock.swift`：7 天签名倒计时估算。
- `Playground/PlaygroundEngine.swift`：试验场的流式 / 生图编排与阶段推进（`@MainActor ObservableObject`）。
- `Guide/DiagnosticsFormat.swift` + `Guide/DiagnosticsChecklist.swift`：诊断的格式化工具与 9 项检查逻辑（把 735 行的单文件拆到 ≤600）。
- `App/AppModels.swift` 中的 `ProviderKindHint`：只做「仅生图预设不能当对话服务商」的中文提示，判定一律转发 `AIProviderConfig.supportsChat` / `PresetProviders.isImageOnly(id:)`，**不自建映射表**。

---

## 7. 关键实现约定

1. **颜色 / 字号 / 间距**：全部走 `Theme` → `AppColor` / `AppFont` / `AppMetrics`（`Support/AppMetrics.swift` 343 行，全部是 `Theme.Spacing.*` 的组合表达式，零裸数值、零 hex）。`consistency_check.py` 扫描结果 `hardcoded_hex=0`、`magic_font=0`。
2. **玻璃质感**：`.ultraThinMaterial` **只允许出现在 `Components/GlassSurface.swift`**；其余所有玻璃效果必须用 `GlassSurface(level:)` 或 `SurfaceCard(style: .glass)`。Reduce Transparency 时降级为 `Theme.surface.opacity(0.94)`。
3. **iOS 16 兼容**：不使用 `@Observable` / `ContentUnavailableView` / `.scrollTargetBehavior` / `.symbolEffect` / `MeshGradient` / `.rect(cornerRadius:)` / `.containerRelativeFrame` / `.presentationBackground`；`.onChange(of:)` 一律单参数闭包写法。
4. **Dynamic Type**：根视图 `.dynamicTypeSize(...DynamicTypeSize.accessibility2)` 限幅，主 App 域允许缩放但不会破版。
5. **生图进度**：`AIResultCard.imageGenerating` 用 `ImageProgress` + `TimelineView(.periodic(from:by:1))` 显示「已等待 N 秒 / 预计 5–20 秒 / 阶段文案」，自绘 `ProgressRing`，**禁止裸 `ProgressView()` 无限转圈**，超 20 秒降级为「仍在绘制，可继续等待」。
6. **四种降级都有中文文案**：无完全访问（`DiagnosticsView` + 键盘主页 ⚠️）、未配置 Key（设置页「未配置」+ 试验场 `ErrorBanner` + 「去配置」）、无网络（`ConnectivityProbe` → 「网络未连接」）、服务端报错（`ErrorPresenter` → `AIError.errorDescription` + `recoverySuggestion`）。
7. **API Key 安全**：只在 `ProviderEditorView` 用 `SecureField` 输入并存 `KeychainStore`；列表、诊断报告、配置导出**默认都不含明文 Key**（导出需显式打开开关且提示风险）。

---

## 8. 自检

```powershell
# 本模块自写静态检查（括号平衡 / 未定义 Theme·AppMetrics 符号 / 重复顶层类型 /
# iOS17+ API / 硬编码颜色 / .font(.system(size: N)) / 玻璃泄漏 / 文件超 600 行 / BOM·CRLF）
$env:PYTHONIOENCODING="utf-8"; python ios/AIKeyboard/selfcheck.py
$env:PYTHONIOENCODING="utf-8"; python ios/AIKeyboard/selfcheck.py -v   # 详细

# 仓库级 QA
$env:PYTHONIOENCODING="utf-8"; python scripts/qa/static_check.py
$env:PYTHONIOENCODING="utf-8"; python scripts/qa/consistency_check.py
$env:PYTHONIOENCODING="utf-8"; python scripts/validate_project.py
```

最近一次结果（提交时）：`selfcheck` 51 文件 / 11,538 行，**P0=0 P1=0 P2=0 通过**；`static_check` **P0=0 P1=0**（唯一 P2 在 `ios/AIKeyboardExtension/`，不属本模块）；`consistency_check` **P0=0 P1=0 P2=0**。

跨 target 顶层类型重名核对：App 133 个类型 ∩ Extension 17 个 = **∅**，App ∩ Shared 54 个 = **∅**，Extension ∩ Shared = **∅**。

---

## 9. 本地化与文案

- 全中文；术语统一：**服务商（Provider）/ 模型 / API Key（UI 显示「API 密钥」）/ 完全访问权限 / 词库 / 短语 / 快捷短语 / AI 试验场 / 续签**。App 名「墨语」。
- 不出现 HTTP 状态码裸奔（401 → 「API Key 无效或已过期」）；不以「出错了 / Error / Oops」开头；数字带单位（「已等待 8 秒」）；按钮 2–4 个汉字；不使用感叹号（欢迎页例外）。
- 模板占位符 `{{text}} {{context}} {{tone}} {{target_language}}` 是字面量，不是英文文案（`PromptLibraryView.swift` 已加 `// i18n-ignore` 注释）。
