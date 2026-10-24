# 墨语（Moyu）· 键盘扩展（AIKeyboardExtension）

> 本目录**只**属于键盘扩展 target（`com.example.moyu.keyboard`）。
> 宿主 App 的界面在 `ios/AIKeyboard/`，共享层在 `ios/Shared/`，两者都不由本模块修改。
> 入口类固定为 `KeyboardViewController`（与 `ios/Config/Extension-Info.plist` 的
> `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).KeyboardViewController` 对应），
> 类名/文件名不可改。

## 1. 文件与视图清单

### 1.1 桌面骨架

| 文件 | 行数 | 职责 |
|---|---:|---|
| `KeyboardViewController.swift` | 201 | `UIInputViewController` 子类：宿主 `UIHostingController`、`heightAnchor` 动态高度、外观跟随、`textDocumentProxy` 注入 |
| `Theme/KMLayout.swift` | 101 | 键盘专用派生度量（唯一高度计算入口 `keyboardHeight(isLandscape:page:safeAreaBottom:)`），全部由 `Theme` 推导 |
| `Support/KMSupport.swift` | 86 | 完全访问探测 `KMFullAccessProbe`、触感 `KMHaptics`、缩略图 `KMImageThumbnail`（≤512px） |
| `Support/KMAnimation.swift` | 40 | Reduce Motion 降级 `KMAnimation`、通用按压样式 `KMPressableStyle` |
| `IME/KMInputEngine.swift` | 97 | `IMECore.IMEKit` 的薄封装单例（词库/学习/短语/剪贴板共用同一份） |

### 1.2 状态机（`ViewModel/`）

| 文件 | 行数 | 职责 |
|---|---:|---|
| `ViewModel/KeyboardState.swift` | 194 | `KeyboardKey`（18 种按键）、`KeyboardViewModel.Page`/`Overlay`/`ShiftState`/`LayoutMode`/`AIAvailability`、`AIResultState`、`KMImageProgress`、`KMAIErrorDetail`、`KMPhrase` |
| `ViewModel/KeyboardViewModel.swift` | 362 | `@MainActor ObservableObject` 主状态机与按键入口 `tap(_:)`、拼音组字、上屏、候选分页、页面路由 |
| `ViewModel/KeyboardViewModel+Access.swift` | 85 | 完全访问判定、AI 可用性优先级、禁用态引导、扩展心跳 |
| `ViewModel/KeyboardViewModel+AI.swift` | 406 | 流式文本生成、生图管线、取消/重试/插入/复制、`AIError` → 中文提示映射、回复建议拆分 |
| `ViewModel/KeyboardViewModel+Panel.swift` | 138 | AI 面板自绘输入框（光标、删除、左右移）、语气、配置导入导出 |

### 1.3 视图（`Views/`）

| 文件 | 行数 | 视图 / 类型 | 契约高度 |
|---|---:|---|---|
| `Views/KeyboardRootView.swift` | 196 | `KeyboardRootView`、`KeyboardShell` | 撑满 `inputView` |
| `Views/CandidateBar.swift` | 128 | `CandidateBar` | 44（固定） |
| `Views/AIBar.swift` | 178 | `AIBar`、`KMAIBarItem`、`KMAIBarDisabledReason` | 40（固定） |
| `Views/KeyCap.swift` | 172 | `KMKeyCap`、`KMKeyLabel`、`KMKeyStyle`、`KMKeyCapStyle` | 视觉 39 / 命中 44 |
| `Views/KeyRows.swift` | 458 | `KeyRowsView`(26 键 + 9 键)、`KMNineKeyGroup`、`NumberPadView`、`SymbolPadView` | 4×39 + 3×6 = 174 |
| `Views/AIPanelView.swift` | 183 | `AIPanelView` | 168 |
| `Views/AIResultCardView.swift` | 332 | `AIResultCardView` | 180（卡片 164） |
| `Views/ExtensionSettingsSheet.swift` | 278 | `ExtensionSettingsSheet`、`SettingsRowButton` | 168（含 52 头部） |
| `Views/EmojiPanelView.swift` | 171 | `EmojiPanelView`、`KMCategory` | 174 |
| `Views/PhraseBarView.swift` | 122 | `PhraseBarView` | 174（浮层，不改总高） |
| `Views/KMAIComponents.swift` | 396 | `KMStreamingText`/`KMProgressDots`/`KMProgressRing`/`KMToneSelector`/`KMPrimaryButton`/`KMSecondaryButton`/`KMErrorBanner`/`KMSheetHeader`/`KMEmptyState` | — |
| `Views/KMGlassSurface.swift` | 77 | `KMGlassSurface`、`KMGlassLevel` | — |
| `Views/KMPillChip.swift` | 126 | `KMPillChip`、`KMPillChipStyle`、`KMPillChipSize` | 30 / 22 / 32 |
| `Views/KMIconGlyph.swift` | 29 | `KMIconGlyph`（SF Symbol 不可用时退回 Unicode） | — |

合计 24 个 Swift 文件。每个文件都 ≤ 600 行（QA `[FILE]` 硬约束）。

## 2. 状态机

```
                      ┌──────────────── tap(.globe) / .dismissKeyboard ────────────────┐
                      │                                    advanceToNextInputMode()     │
                      ▼                                                                │
   ┌──────────┐  ⇧/123/#+=  ┌─────────┐  ┌─────────┐  🙂  ┌───────┐                   │
   │ .letters │────────────▶│.numbers │  │.symbols │     │.emoji │                   │
   │ (26/9 键)│◀────────────│         │─▶│         │     │       │                   │
   └────┬─────┘    ABC      └────┬────┘  └────┬────┘     └───┬───┘                   │
        │                       │            │              │                       │
        │                       └────────────┴──────────────┘                       │
        │  AI 工具条 chip / 横屏 ✨ 钮                                                  │
        ▼                                                                             │
   ┌───────────┐  submitPanel(feature) / startAI(feature)                              │
   │ .aiPanel  │──────────────────────────────────────┐                               │
   │  (+168)   │◀── editAIResult()                    │                               │
   └─────┬─────┘                                      ▼                               │
         │ closeAIPanel                          ┌────────────┐                        │
         │                                       │  .result   │                        │
         │        ┌──────────────────────────────│  (+180)    │                        │
         │        │  插入 / 复制 / 关闭 / 重试      └─────┬──────┘                        │
         │        │                                     │                               │
         ▼        ▼                                     ▼                               │
   ┌──────────────────────── 上一页（previousNonAIPage）──────────────────────────────┐  │
   └──────────────────────────────────────────────────────────────────────────────────┘  │
                                                                                          │
   ⚙️ 设置 chip ──▶ ┌───────────┐  closeSettings ──▶ .letters                             │
                    │ .settings │                                                         │
                    │  (+168)   │◀── 未配 Provider / 401 的「去设置」                      │
                    └───────────┘                                                         │
                                                                                          │
   Overlay（浮层，不改高度，叠加在键区之上）：                                              │
      .phraseBar     ← tap(.openPhraseBar)     / tap(.closeOverlay) ─┐                    │
      .clipboardBar  ← tap(.openClipboardBar)                         │                    │
                                                                    ▼                    │
                                                             .none（回到页面）────────────┘

   页面状态：Page { letters, numbers, symbols, emoji, aiPanel, result, settings }
   浮层状态：Overlay { none, phraseBar, clipboardBar }（与 Page 正交，可叠加）

   AI 结果子状态 AIResultState：
      idle ──startAI──▶ streaming(text) ──isFinal──▶ done(text)
                            │                           │
                            ├──throw──▶ failed(title)    └─insertAIResult──▶ idle（回上一页）
                            │
      startAI(AIFeature.image) ─▶ imageGenerating(KMImageProgress)
                                     ├──成功──▶ image(Data ≤512px 缩略图)
                                     └──失败──▶ failed(title)
                            cancelAI() ─▶ idle

   所有按键动作的唯一入口：KeyboardViewModel.tap(_ key: KeyboardKey)
```

## 3. 键盘高度策略

**唯一高度计算入口**：`KMLayout.keyboardHeight(isLandscape:page:safeAreaBottom:)`，
**唯一应用点**：`KeyboardViewController.applyHeight(animated:)`。其它任何地方都不许改高度。

| 场景 | 高度 | 组成 |
|---|---:|---|
| 竖屏基础（.letters/.numbers/.symbols/.emoji） | **258** | 44 候选栏 + 40 AI 工具条 + 174 键区（4×39 + 3×6） |
| 竖屏 `.aiPanel` / `.settings` | **426**（+168） | 8 + 44 输入框 + 8 + 44 语气行 + 8 + 44 生成按钮 + 12 |
| 竖屏 `.result`（含生图绘制中） | **438**（+180） | 8 + 卡片 164（header 28 + body 92 + actions 44）+ 8 |
| 横屏基础 | **200** | 44 + 4×34.5 + 3×6；AIBar 折叠为候选栏右侧 32×32 ✨ 钮 |
| 横屏 `.aiPanel` / `.settings` / `.result` | **340**（+140） | 横屏弹层 |

- 展开时**候选栏与 AI 工具条位置完全不动**，新增高度从工具条下方向上挤出。
- 数字符号页、Emoji 页与字母页同高（258），切页不抖动。
- 底部安全区：`258` 是纯键盘高度，`inputView` 不含 Home Indicator；
  `applyHeight` 里 `safeAreaBottom` 只在竖屏计入（横屏传 0）。
- 动效（`design/键盘布局规范.md` §6）：
  - 展开：`UIViewPropertyAnimator(duration: 0.35, dampingRatio: 0.82)`
  - 收起：`UIViewPropertyAnimator(duration: 0.28, dampingRatio: 0.9)`
  - `UIAccessibility.isReduceMotionEnabled` 时直接切换，无动画。
  - 快速连点时先 `heightAnimator?.stopAnimation(true)`，避免高度抖动。

### 3.1 iOS 16 的 `requestInputViewHeightUpdate` 兼容方案

`requestInputViewHeightUpdate()` 是 iOS 16 后期才补充的 API，在 `IPHONEOS_DEPLOYMENT_TARGET=16.0`
下不能直接调用（会编译失败）。因此：

1. **主路径**：直接修改挂在 `view` 上的 `heightAnchor.constraint(equalToConstant:)` 常量，
   然后 `view.layoutIfNeeded()`。扩展的 `inputView` 高度由这条约束决定，宿主会随之重新测量。
2. **可选加速**：`requestHeightUpdateFromSystem()` 通过 `NSSelectorFromString("requestInputViewHeightUpdate")`
   + `responds(to:)` + `perform(_:)` 动态转发；系统没实现时静默跳过，**不产生编译期依赖**。
3. **兜底**：无论哪条路径，末尾都会 `inputView?.setNeedsLayout()`。

> 结论：iOS 16 上行为等价于「约束 + 布局」，iOS 17+ 若系统提供了该方法则自动走快速路径。

## 4. 降级路径

| 场景 | 判定 | 键盘内表现 | 能否恢复/跳转 |
|---|---|---|---|
| **无完全访问** | `UIInputViewController.hasFullAccess == false` 且 `KMFullAccessProbe.likelyAvailable() == false` | AI 工具条整条禁用（`opacity 0.55`）→「开启完全访问后可用 AI ›」；点提示弹**文字说明卡**（5 步设置路径）。**不发任何网络请求**。输入法本体（26 键/候选/emoji/短语）完全可用 | **不能跳转**：扩展内没有 `openURL` 能力，只能文字引导用户自己去「设置 › 通用 › 键盘 › 墨语 › 允许完全访问」 |
| **未配置 Provider** | `snapshot.defaultProvider == nil` 或 `!snapshot.isChatReady` | 工具条「还没有配置 AI 服务 · 点此设置 ›」→ 点进 `.settings` 页（键盘内可切服务商/语气，完整编辑在宿主 App） | 点开「墨语」App 配置后回到键盘即生效（`viewWillAppear` 重读 `ConfigStore`） |
| **无网络** | 流式请求抛 `AIError.network`/`.timeout`，或错误详情 `isOffline` | 结果卡片失败态：`KMErrorBanner`「网络连接失败」+ `recoverySuggestion`；`aiAvailability` 置 `.offline`，工具条显示「网络未连接 ›」 | 恢复网络后点「重试」即可 |
| **宿主不支持插图** | 生图只能走剪贴板（`UIPasteboard.general.image`） | 结果卡片显示缩略图 + 「复制图片」按钮；点击后 Toast「复制后在聊天窗口长按输入框粘贴」 | 用户手动在聊天框长按粘贴；**本扩展不会也不能直接往宿主输入框插图片** |
| **服务端报错** | `AIError.server(5xx)` / `.rateLimited` / `.contentRejected` | 失败态卡片：`errorDescription` + `recoverySuggestion`，401 给「去设置」、429 提示「请求太频繁，请稍后再试」 | 可重试；不可重试的（401/notConfigured）引导去设置 |

错误映射集中在 `KeyboardViewModel+AI.swift` 的 `static func errorDetail(from: AIError) -> KMAIErrorDetail`，
文案取自 `AIError.errorDescription` / `recoverySuggestion`（Shared 层已中文化）。

## 5. 已知限制

1. **键盘内设置只做「选择 / 切换 / 导入」**：`.settings` 页（426pt）只能切默认服务商、切默认语气、
   看快捷短语、开关剪贴板历史、导入导出配置快照；**Provider 的新增/编辑、API Key 填写、提示词编辑、
   完整短语管理都在宿主 App「墨语」里完成**（扩展内输入体验受限且容易被系统回收，不适合编辑长文本）。
2. **生图无法直接插入**：iOS 键盘扩展没有向宿主文本框插入图片的公开 API，只能
   `UIPasteboard.general.image = image`，然后提示「复制后在聊天窗口长按输入框粘贴」。
3. **AI 面板输入框为自绘**：P0 允许降级为「只读上下文 + 点 chip 直接生成」。当前实现是
   **焦点重定向自绘输入**（支持编辑、光标、删除、一键填入当前输入框内容 / 从剪贴板取上下文），
   如果实机发现布局抖动或输入异常，可退化为只读模式（`AIPanelView` + `+Panel.swift` 已隔离，
   改动面仅这两个文件）。
   **为什么不使用 SwiftUI `TextField`**：键盘扩展进程里无法可靠弹出系统键盘（扩展本身是输入源，
   会形成输入源抢占/键盘相互挤压），且 `TextField` 获得焦点后宿主 App 的 `textDocumentProxy`
   行为不确定，容易造成布局抖动与光标丢失。因此输入框用 `Button` 进入编辑态，字符由本键盘自己的
   按键事件经 `panelInsert(_:)` 写入 `panelText`。

## 6. 设计令牌与组件命名映射

颜色 / 字号 / 间距 / 圆角 / 阴影 / 材质**全部**从 `ios/Shared/Theme/Theme.swift` 取，
本目录内没有任何 `#RRGGBB` 字面量（QA `consistency_check.py` 校验为 0）。

设计层（`design/组件库.md`）约定的组件名 → 扩展实现名（**实现层统一加 `KM` 前缀**）：

| 设计层 | 扩展实现 | 原因 |
|---|---|---|
| `PillChip` | `KMPillChip` | 宿主 App `ios/AIKeyboard/Components/PillChip.swift` 已占用该顶层名，虽然两 target 不互通，但 QA `[DUP-DECL]` 按 `(kind, name)` 全局判重 |
| `GlassSurface` | `KMGlassSurface` | 同上（App 侧已有 `GlassSurface`） |
| `IconGlyph` | `KMIconGlyph` | 同上 |
| `PrimaryButton` / `SecondaryButton` | `KMPrimaryButton` / `KMSecondaryButton` | 同上 |
| `StreamingText` / `ProgressDots` / `ProgressRing` | `KMStreamingText` / `KMProgressDots` / `KMProgressRing` | 同上 |
| `ToneSelector` / `SheetHeader` / `ErrorBanner` / `EmptyState` | `KMToneSelector` / `KMSheetHeader` / `KMErrorBanner` / `KMEmptyState` | 同上 |
| `KeyCap` / `CandidateBar` / `AIBar` | `KMKeyCap` / `CandidateBar` / `AIBar` | 后两者 App 侧未占用，保持原名 |
| `AIResultCard` | `AIResultCardView` | App 侧已有 `AIResultCard`（视觉一致，实现独立） |

> 视觉与 `design/组件库.md` 一致，实现独立（扩展 target 不编译 `ios/AIKeyboard/**`）。

## 7. 与宿主 App 的契约（心跳）

宿主 App 的诊断页通过 `SharedStore` 读取两个键（**键名逐字固定**，不可改）：

| 键 | 写入时机 | 读取方 |
|---|---|---|
| `moyu.ext.lastActiveAt` | `KeyboardViewModel.activate()`（键盘每次唤起） | 宿主 App 诊断页「扩展活跃」 |
| `moyu.ext.lastNetworkOKAt` | `finishTextGeneration` / `finishImageGeneration` 成功分支 | 宿主 App 诊断页「网络连通」 |

数值为 `Date().timeIntervalSince1970`（`Double`），通过
`SharedStore.shared.setDouble(_:forKey:)` 写入，读取用 `SharedStore.shared.double(forKey:default:)`。

## 8. 共享层依赖（本模块只读引用）

`ios/AIKeyboardExtension/` 依赖以下**已落盘**的 Shared 符号，全部由 ai-service / ime-core 维护：

- 主题：`Theme`（颜色 38、字体 12、`Spacing`/`Radius`/`Sizing`/`Motion`/`Shadow`/`MaterialToken`）
- 模型：`AIFeature`、`AIProviderConfig`、`ConfigSnapshot`、`ChatMessage`、`ChatRequest`、`ChatDelta`、`ImageRequest`、`GeneratedImage`
- 网络：`LLMClient`、`ImageGenerating`、`AIClientFactory`、`AIError`
- 提示词：`PromptLibrary`、`BuiltInPrompts`、`PromptTemplate`
- 存储：`SharedStore`、`SharedStoreKey`、`ConfigStore`、`KeychainStore`、`PasteboardBridge`
- 输入引擎：`IMEKit`、`IMECandidate`、`PhraseItem`

扩展侧**不自建**词库/引擎/配置存储，避免双份词库内存与学习数据不共享。

## 9. 编码与自查

- 4 空格缩进、UTF-8 无 BOM、LF；单文件 ≤600 行。
- 无 `try!` / `as!` / `fatalError`；无 `UIApplication`（扩展硬禁令）。
- 全部用户可见文案为中文；每个可点元素带 `.accessibilityLabel`，命中区 ≥44pt。
- 自查：
  ```bash
  python scripts/qa/static_check.py --no-color
  python scripts/qa/consistency_check.py --no-color
  python ios/AIKeyboardExtension/selfcheck.py
  ```
