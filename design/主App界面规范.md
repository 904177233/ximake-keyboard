# 主 App 界面规范 · Host App Screen Spec

> 版本 v1.0 ｜ 适用：`ios/AIKeyboard/`（host-app-ui）
> 依据：`docs/01` PRD §4.3、`docs/02` §4.8、`design/tokens.json`、`design/组件库.md`
> 画布：iPhone 390×844pt，iOS 16.0+；**所有页面必须深色模式可用**
> 统一容器：`NavigationStack`（iOS 16 可用）。**禁止** `NavigationSplitView`（iPad 也未要求）。

---

## 0. 全局规范（先定这些，再逐屏）

### 0.1 导航结构

```
RootView
├─ if !hasCompletedOnboarding → OnboardingView（全屏，无 Tab）
└─ MainTabView（TabView，3 个标签）
   ├─ Tab 1「键盘」 KeyboardHomeView   keyboard.circle → 图标用 SF `keyboard`
   ├─ Tab 2「AI」   PlaygroundView     `sparkles`
   └─ Tab 3「设置」 SettingsView        `gearshape`
```
- TabBar 高度 49 + 安全区（`sizing.tabBarHeight`），**用系统 TabView**，不自绘（省事且原生）。
- Tab 标题：键盘 / AI / 设置（中文，2 字）。
- 设置页二级页面用 `NavigationLink` push；Provider 编辑、Prompt 编辑用 **Sheet**（`.presentationDetents([.large])`，iOS 16 可用）。
- 导航标题：全部 `.large` 大标题；二级页面 `.inline`。
- 返回按钮文案统一「返回」（在 `MainTabView` 里用 `.navigationBarBackButtonHidden` + 自定义，或留系统默认——系统默认会显示上一页标题，注意上一页标题别太长）。

### 0.2 页面栅格

| 项 | 值 | tokens 键 |
|---|---:|---|
| 屏幕左右边距 | **16** | `spacing.screenMargin` |
| 分组卡片圆角 | 16 | `radius.card` |
| 分组卡片内行高 | 44 | `spacing.rowMinHeight` |
| 分组间距（组与组之间） | 28 | `spacing.sectionGap` |
| 组内分隔线缩进 | 左 16（与文字对齐） | — |
| 大标题行高 | 52 | `sizing.largeTitleHeight` |
| 导航栏高 | 44 | `sizing.navBarHeight` |
| 底部安全区 | 34 | `sizing.homeIndicatorHeight` |

**页面统一骨架**：

```swift
ScrollView {
    VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
        // 各组 SectionHeader + SurfaceCard
    }
    .padding(.horizontal, Theme.Spacing.screenMargin)
    .padding(.bottom, Theme.Spacing.xxl)
}
.background(Theme.surfaceGrouped)      // 分组背景 = #F2F2F7 / 深色 #000000
```

> 与键盘的差异：**主 App 用「灰底 + 白卡」的 iOS 设置页语言**（`surfaceGrouped` 底 + `SurfaceCard` 白卡）；键盘内是「玻璃条 + 键帽」的键盘语言。两套不能混。

### 0.3 页面清单与优先级

| # | 页面 | Swift 类型 | 入口 | P |
|---|---|---|---|---:|
| 1 | 引导 | `OnboardingView` | 首启 | P0 |
| 2 | 键盘主页 | `KeyboardHomeView` | Tab1 | P0 |
| 3 | 设置 | `SettingsView` | Tab3 | P0 |
| 4 | Provider 列表 | `ProviderListView` | 设置›AI 服务 | P0 |
| 5 | Provider 编辑 | `ProviderEditorView` | 列表›+ / 点击 | P0 |
| 6 | Prompt 模板库 | `PromptLibraryView` | 设置›Prompt 模板 | P0 |
| 7 | Prompt 编辑 | `PromptEditorView` | 模板库›+/点击自定义 | P0 |
| 8 | AI 试验场 | `PlaygroundView` | Tab2 | P0 |
| 9 | 安装与续签指南 | `InstallGuideView` | 设置›安装与续签 | P0 |
| 10 | 诊断 | `DiagnosticsView` | 设置›诊断 | P0 |
| 11 | 关于 | `AboutView` | 设置›关于 | P1 |
| 12 | 配置导入导出 | `ConfigTransferView` | 设置›同步到键盘 | P0 |

---

## 1. `OnboardingView` —— 5 步引导（硬性 5 步，不许增减）

**背景**：无 Apple 开发者账号、只有 Windows 的用户。所以引导必须承认现实：编译要在 Mac 或 **GitHub Actions 云编译**，装到手机用 **iloader**。

### 1.1 结构

- 全屏 `TabView(selection:).tabViewStyle(.page(indexDisplayMode: .never))`，**禁止**默认圆点（自绘步骤条）。
- 顶部：步骤条 5 段（每段 24×3 圆角 2，已完成 accent，当前 accent 0.6，未完成 separator）。
- 中部：图标区（120×120，`RoundedRectangle(28)` + 玻璃渐变底 + 48pt SF Symbol）。
- 标题 28pt bold（`typography.largeTitle` 偏小一号，用 28），正文 15pt `text.secondary`，行距 1.5。
- 底部：`PrimaryButton("下一步")` 高 50 + 上方「跳过」文字按钮（13pt，仅第 1、2、5 步可跳过；第 3 步「开完全访问」不可跳过，因为 AI 必须有它）。

### 1.2 五步内容（逐字文案）

| 步 | 图标 | 标题 | 正文（≤3 行） | 主按钮 | 次按钮 |
|---|---|---|---|---|---|
| 1 | `sparkles` | 欢迎使用墨语 | 「一颗会 AI 的输入法。打字时随手润色、翻译、生成回复，不用切 App。」 | 开始设置 | 跳过 |
| 2 | `square.grid.2x2` | 第 1 步 · 添加键盘 | 「设置 › 通用 › 键盘 › 键盘 › 添加新键盘 › 墨语。加完后在聊天框里长按地球键就能切换。」 | 我已完成 | 稍后 |
| 3 | `lock.shield` | 第 2 步 · 开启完全访问 | 「设置 › 通用 › 键盘 › 墨语 › 打开「允许完全访问」。不开这个，键盘就无法联网，AI 不可用。」 | 我已开启 | 查看图示 |
| 4 | `server.rack` | 第 3 步 · 配置 AI 服务 | 「填一个 baseURL + API Key + 模型名就能用。支持 DeepSeek、通义千问、Kimi、智谱、OpenRouter 等 9 家预设。」 | 去配置 | 稍后 |
| 5 | `checkmark.seal` | 第 4 步 · 装到手机上 | 「没有 Mac？用 GitHub Actions 云端编译出 ipa，再用 iloader 装到 iPhone（免费 Apple ID 每 7 天续签一次）。」 | 看安装指南 | 完成 |

> 标题里的「第 N 步」是**页面内步骤**（2~5），第 1 步是欢迎页不编号。这一点在 UI 里要一致。

### 1.3 关键交互

- 第 2 步「查看图示」：底部弹 `Sheet`，展示 3 张**纯 SwiftUI 绘制**的设置路径示意图（不用截图，避免素材缺失）：路径文字 + 箭头 + 高亮框。
- 第 3 步「查看图示」同上；并有 `Button("去系统设置")` 调 `UIApplication.openSettingsURLString`（**只能到本 App 设置页，到不了键盘设置**，UI 上必须写一句「系统限制：无法直接跳到键盘设置，请按路径手动进入」——这是诚实设计）。
- 第 4 步「去配置」→ push `ProviderEditorView`（首次为空态，直接进新增）。
- 第 5 步「看安装指南」→ push `InstallGuideView`。
- 完成后写 `UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")`，进 `MainTabView`。
- **进度持久化**：中途退出 App，下次回到第 N 步（存 `onboardingStep`）。

### 1.4 空态 / 错误

- 无（引导页不涉及网络），但第 4 步若用户点「去配置」后直接返回，回到第 4 步并显示一个小提示「随时可以在 设置 › AI 服务 里修改」。

---

## 2. `KeyboardHomeView` —— Tab1「键盘」

作用：**告诉用户键盘现在是什么状态，并给一个 2 秒能懂的修复入口**。这是一个「状态仪表盘」，不是功能页。

```
大标题：键盘
┌─ 状态卡（SurfaceCard，玻璃高光）───────────┐
│   [keyboard 40]  墨语键盘                  │
│                  已添加 · 完全访问已开启    │
│                  ✅ 一切就绪                │
└────────────────────────────────────────────┘
┌─ 分组：快速开始 ───────────────────────────┐
│ 🌐 添加键盘                ›               │
│ 🔓 开启完全访问            ›               │
│ ✨ 配置 AI 服务            已配置 1 个  ›   │
└────────────────────────────────────────────┘
┌─ 分组：在聊天里试一下 ─────────────────────┐
│ [ 打开微信试试 ]（SecondaryButton 全宽）    │
│ 提示：iOS 不允许 App 直接打开其它 App，     │
│ 请手动切到微信，长按地球键切换到墨语。       │
└────────────────────────────────────────────┘
```
- **状态判定**：完全访问无法从宿主 App 直接查询（iOS 无公开 API）。启发式：在 `SharedStore` 里由扩展写入「最近一次心跳时间戳」（扩展每次激活写一次），App 读取判断「键盘最近 24 小时内被使用过」→ 显示「已添加」。完全访问则看「扩展是否写入过成功联网的时间戳」。**UI 上对不确定的状态必须写「可能未开启」而不是断言**，并在旁边给「如何确认」入口。
- 三态：✅ 一切就绪 / ⚠️ 部分就绪（缺 1~2 项）/ ⚪ 未设置（全缺）。
- **空态**：什么都没设置时，状态卡变成 `EmptyState`（图标 `keyboard`，标题「还没有添加键盘」，正文「按 3 步完成设置」，按钮「开始设置」→ push Onboarding）。

---

## 3. `SettingsView` —— Tab3「设置」

标准 iOS 设置页。分组顺序（从上到下，**顺序固定**）：

| 组 | 行 | 类型 | 说明 |
|---|---|---|---|
| AI | AI 服务 | 跳转 + 右侧「DeepSeek」 | 显示默认 Provider 名；未配置显示「未配置」红色 |
| AI | 默认语气 | 跳转/内联 Picker | 自然/简洁/礼貌/正式/热情（5 项） |
| AI | 回复建议条数 | Stepper 3 | 范围 1~5，默认 3 |
| AI | 生图尺寸 | 跳转 | 1024×1024 / 768×1024 / 1024×768 |
| AI | Prompt 模板 | 跳转 + 「12」 | 内置 10 + 自定义 2 |
| 键盘 | 键盘布局 | Segmented（26 键 / 9 键） | 写 `SharedStore`，扩展读 |
| 键盘 | 候选字号 | Segmented（标准 / 大） | 17 / 19 |
| 键盘 | 按键音 | Toggle | 默认关 |
| 键盘 | 振动反馈 | Toggle | 默认开 |
| 隐私 | 剪贴板历史 | Toggle | 默认**关**（隐私优先）；关时下面一行灰字「关闭后键盘不读取剪贴板」 |
| 隐私 | 本地学习 | Toggle | 默认开；副标题「词频与自造词只存在本机」 |
| 隐私 | 清除本地数据 | 红色文字按钮 | 二次确认 Alert |
| 同步 | 同步到键盘 | 跳转 `ConfigTransferView` | 免费账号无 App Group 的搬运入口 |
| 支持 | 安装与续签指南 | 跳转 | |
| 支持 | 诊断 | 跳转 + 状态点 | 绿色/黄色/红色圆点 |
| 支持 | 关于 | 跳转 + 版本号 | 1.0.0 (1) |
| 危险 | 重置所有设置 | 红色 | 二次确认 |

**行样式**：`SettingsRow`（见组件库）——左图标 28×28 圆角 7 底色 `accent.soft`（不同分组可用不同色：AI=accent 蓝、键盘=gray、隐私=green、危险=red），标题 17pt，右侧值 17pt `text.secondary` + chevron。

**版本号与签名剩余天数**：设置页最底部（`关于` 组下方）显示一行 12pt `text.tertiary` 居中：
`墨语 1.0.0 (1) · 签名剩余 6 天`
签名剩余天数：从安装日期（首次运行写入 `UserDefaults`）算 7 天倒计时；≤2 天时该行变 `warning` 色并加一个「续签指南」链接。

---

## 4. `ProviderListView` + `ProviderEditorView`

### 4.1 `ProviderListView`

```
大标题：AI 服务
┌─ SurfaceCard ──────────────────────────────┐
│ [D] DeepSeek          默认 ✓         ›     │
│     deepseek-chat · 已连接                  │
├────────────────────────────────────────────┤
│ [Q] 通义千问                         ›     │
│     qwen-plus · 未测试                      │
└────────────────────────────────────────────┘
[ + 添加服务 ]  ← 底部大按钮，或导航栏右上 + 
```
- 每行：左侧 36×36 圆角 10 的字母头像（取 Provider 名首字，背景 `accent.soft`，文字 accent 17 semibold）；主标题 17；副标题 13 `text.secondary`（模型名 · 状态）；右侧 chevron。当前默认行主标题右侧一个 `checkmark.circle.fill` accent。
- 状态文案：`已连接`（绿）/ `未测试`（灰）/ `连接失败`（红）。
- **左滑删除**（`.swipeActions`，iOS 15+ 可用），删除需确认；默认 Provider 被删时自动选第一个。
- **空态**：`EmptyState(icon: "server.rack", title: "还没有 AI 服务", message: "添加一个服务商，键盘里的 AI 才能用", action: "添加服务")`。
- 顶部一行提示条（`info` 样式，13pt）：「API Key 只存在本机钥匙串，不会上传到任何服务器」。

### 4.2 `ProviderEditorView`（Sheet，`Form` 风格但自绘）

字段顺序（**固定**）：

| # | 字段 | 控件 | 规则 |
|---|---|---|---|
| 1 | 服务商预设 | 横滑 `PillChip` 组（9 个） | DeepSeek / 通义千问 / Kimi / 智谱 GLM / 火山方舟 / OpenRouter / 硅基流动 / OpenAI / Anthropic / 自定义 |
| 2 | 名称 | TextField | 选预设自动填，可改 |
| 3 | 调用协议 | Segmented（OpenAI 兼容 / Anthropic / Gemini） | 选预设自动定 |
| 4 | Base URL | TextField（`.keyboardType(.URL)`, `.autocapitalization(.none)`） | 自动填，可改；尾部斜杠自动归一 |
| 5 | API Key | SecureField + 「显示」眼睛 | 存 Keychain；已存在时显示 `••••••••` + 「已保存」 |
| 6 | 模型 | TextField + 建议 chips | 预设给 3~5 个常见模型，点选填入 |
| 7 | 生图模型（可选） | TextField | 折叠在「高级」里 |
| 8 | Temperature | Slider 0~2，步进 0.1，右侧数值 | 默认 0.7 |
| 9 | 最大 Tokens | Stepper 128~4096 步进 128 | 默认 1024 |
| 10 | 超时（秒） | Stepper 10~120 步进 5 | 默认 30 |
| 11 | 自定义 Header（可选） | 折叠区，KV 行 | 中转站需要 |
| 12 | 设为默认 | Toggle | 首个自动开 |
| — | **测试连接** | `SecondaryButton` 全宽 | 流式请求「你好，用一句中文回复」；成功显示绿条「连接成功 · 模型 deepseek-chat · 0.8s」，失败显示红条 + `AIError.recoverySuggestion` |
| — | 保存 | 导航栏右上「保存」（禁用态直到必填齐全） | 必填：名称/BaseURL/Key/模型 |

- Sheet 顶部 `SheetHeader(title: "添加服务", onClose:)`，或 NavigationStack + `.toolbar` 的「取消 / 保存」（iOS 习惯，采用后者）。
- 表单背景 `surfaceGrouped`，字段组用 `SurfaceCard` 包，组间距 12。
- **脱敏**：API Key 在任何列表/导出中都不显示明文；`PasteboardBridge.export` 默认 `includeAPIKeys: false`。

---

## 5. `PromptLibraryView` + `PromptEditorView`

### 5.1 列表

```
大标题：Prompt 模板
SegmentedTabs: [全部] [润色] [扩写] [翻译] [回复] [生图] [自定义]
┌─ 内置模板 ────────────────────────────────┐
│ ✨ 润色         只输出改写后的正文      ›  │
│ 💬 一句扩写     扩成 2~4 句             ›  │
│ 🌐 翻译         自动识别方向            ›  │
│ 🧠 回复建议     恰好 3 条               ›  │
│ 🎨 生图         提示词增强              ›  │
└───────────────────────────────────────────┘
┌─ 自定义 ─────────────────────────────────┐
│ ⚙️ 我的小红书文案  ...                  ›  │
└───────────────────────────────────────────┘
```
- 内置模板**只读**（点击进详情，底部「在试验场试用」，不能编辑，但可「复制为自定义」）。
- 自定义模板可编辑/删除（左滑）。
- 每行右侧一个 `chevron`；行副标题显示 `userTemplate` 前 20 字（截断）。

### 5.2 `PromptEditorView`（Sheet）

字段：名称 / 图标（SF Symbol 选择器：给 12 个候选网格）/ 类型（AIFeature Picker）/ 系统提示（多行 TextEditor，minHeight 120）/ 用户模板（多行，说明「支持 {{text}} {{context}} {{tone}} {{target_language}}」）/ Temperature 滑杆 / 是否流式 Toggle。底部「在试验场试用」+ 导航栏「保存」。

---

## 6. `PlaygroundView` —— Tab2「AI 试验场」

**这是主 App 的门面页**，要一眼看懂「这个输入法的 AI 能干什么」。

```
大标题：AI 试验场
┌─ 输入区 SurfaceCard ───────────────────────┐
│  TextEditor 占位「输入一段话，试试 AI…」    │  120
│  ─────────────────────────────────────      │
│  字数 0/2000              [清空]            │
└────────────────────────────────────────────┘
┌─ 能力 chips（横向滚动 PillChip）──────────┐
│ [✨润色] [💬扩写] [🌐翻译] [🧠回复] [🎨生图] │
└────────────────────────────────────────────┘
┌─ 参数行 ──────────────────────────────────┐
│ Provider [DeepSeek ▾]  语气 [自然 ▾]       │
└────────────────────────────────────────────┘
[ 生成 ]  ← PrimaryButton 50 全宽
──────── 结果区 ────────
┌─ 结果卡（AIResultCard）────────────────────┐
│ ✨ 润色 · DeepSeek · 已完成 1.2s      [×] │
│ 正文…（StreamingText，maxHeight 无限）     │
│ [复制] [保存为短语] [重试]                 │
└────────────────────────────────────────────┘
```

**生图态（必须实现，用户明确要求）**：

```
┌─ 生图卡 ──────────────────────────────────┐
│ 🎨 生图 · 通义万相                        │
│ ┌────────┐  绘制中…                       │
│ │ 进度环 │  已等待 8 秒                    │
│ │  48pt  │  预计 5–20 秒                   │
│ └────────┘  [取消]                        │
│ 提示词：一只在打字的橘猫（已增强为英文）     │
└───────────────────────────────────────────┘
```
- 进度环用 `ProgressView` 的**不确定**样式要禁止；用 `Circle().trim(from:0,to: progress)` 自绘 + 旋转，progress 按 `elapsed / 20` 封顶 0.9（不装真实进度，避免假装精确）。
- 每秒刷新「已等待 N 秒」（`TimelineView(.periodic(from:.now, by:1))`）。
- 阶段文案由 AIService 提供（若拿不到阶段，就循环显示「正在绘制…」）。
- **>20 秒**：文案变「仍在绘制，可继续等待」，出现「重试」按钮（取消 + 重新发）。
- 完成：`AsyncImage` 不行（数据在内存/临时文件），用 `Image(uiImage:)`；缩略图 120×120 圆角 12；下方「复制图片」「保存到相册」——**保存到相册需要 `NSPhotoLibraryAddUsageDescription`**，如未申请则只保留「复制图片」。

**结果卡动作**：文本 → 复制 / 保存为短语 / 重试 / 关闭；生图 → 复制图片 / 重试 / 关闭。

**空态**：未配置 Provider 时，输入框禁用 + `EmptyState("server.rack", "还没有配置 AI 服务", "添加后即可在试验场试用全部能力", "去配置")`。

---

## 7. `InstallGuideView` —— 安装与续签（重点是「没有 Mac」）

用「步骤卡」纵向排列（`StepCard`），每步含：序号圆点、标题、正文、可选代码块、可选「复制」按钮。

| 步 | 标题 | 内容要点 |
|---|---|---|
| 1 | 准备签名方式 | 两条路：A. 有 Mac → Xcode 直接 Run（推荐）；B. 只有 Windows → GitHub Actions 云编译出 ipa |
| 2 | 云编译（无 Mac） | 把仓库 push 到自己的 GitHub 私有库 → 在 Actions 里运行 `Build IPA` workflow → 下载 Artifacts 里的 `.ipa`。**给一段可复制说明**，不要给假链接 |
| 3 | 用 iloader 安装 | Windows 装 iloader（开源，不需要管理员权限）→ 连 iPhone → 填 Apple ID 与密码 → 2FA → Import IPA → Sign & Install App。首次需要在 iPhone「设置 › 通用 › VPN与设备管理」里信任开发者 |
| 4 | 添加键盘 + 开完全访问 | 同引导第 2、3 步，给路径文字 |
| 5 | 7 天续签 | 免费 Apple ID 签名 7 天过期，过期后键盘会消失。三种续签方式对比表（Xcode 重新 Run / iloader 重装 / AltStore 自动续签），推荐 AltStore（需常驻电脑或 AltServer） |

**续签对比表**（表格，UI 用 `SurfaceCard` + 3 列）：

| 方式 | 需要什么 | 频率 | 适合 |
|---|---|---|---|
| Xcode 重新 Run | Mac | 每 7 天 | 有 Mac 的人 |
| iloader 重装 | Windows + 数据线 | 每 7 天 | 偶尔用 |
| AltStore 自动续签 | Windows 常开 AltServer（同一 Wi-Fi） | 自动 | 长期自用（推荐） |

**顶部提醒卡**：`warning.soft` 底 + `exclamationmark.triangle` 图标：「免费签名 7 天过期是 Apple 的限制，不是 App 的问题。」+ 「查看签名剩余天数」（从安装日期算）。

**可复制清单**：底部一个 `Text` 代码块，列出「续签 checklist」，右侧「复制」按钮复制到剪贴板。

---

## 8. `DiagnosticsView` —— 诊断

自检项列表（每项：图标 + 名称 + 状态点 + 说明 + 可选操作）：

| 检查项 | 判定方式 | 状态 | 说明文案（失败时） |
|---|---|---|---|
| 键盘扩展已添加 | 扩展心跳时间戳（`SharedStore` 写） | ✅/⚠️/❓ | 「24 小时内没有检测到键盘被使用。可能没添加，或只是没切过去。」 |
| 完全访问权限 | 扩展是否写入过「联网成功」时间戳 | ✅/⚠️/❓ | 「AI 需要联网权限。请在 设置 › 通用 › 键盘 › 墨语 中开启。」 |
| AI 服务配置 | `ConfigSnapshot.providers` 非空 | ✅/❌ | 「还没有配置 AI 服务。」+「去配置」 |
| API 连通性 | 点击「测试」发一次最小请求 | ⏳/✅/❌ | 显示具体 `AIError` 中文 + 恢复建议 |
| Keychain 可写 | 写读删一个测试项 | ✅/❌ | 「钥匙串不可用，API Key 无法保存。」 |
| 本地词库 | `PinyinDictionary.bundled().version / wordCount` | ✅ | 「词库 v1 · 5321 词」 |
| 存储模式 | `SharedStore.isAppGroupAvailable` | ℹ️ | 「当前：标准 UserDefaults（免费账号）/ App Group」 |
| 配置快照 | 导出 JSON 大小 + 版本 | ✅ | 「配置 v1 · 2 个服务 · 3.2KB」 |
| 网络 | `NWPathMonitor` 当前状态 | ✅/❌ | 「当前无网络连接。」 |

- 顶部「全部重测」按钮；底部「导出诊断报告」（复制的纯文本，便于发给别人求助）。
- 状态点：✅ green / ⚠️ warning / ❌ danger / ℹ️ secondary / ⏳ 转圈。

---

## 9. `ConfigTransferView` —— 同步到键盘（免费账号的核心痛点页）

**背景**：无 App Group，App 与扩展各自 UserDefaults，靠命名 `UIPasteboard` 搬运。这个页面必须把原理讲清楚，否则用户会以为坏了。

```
大标题：同步到键盘
┌─ 说明卡 ──────────────────────────────────┐
│ ℹ️ 免费签名不支持 App Group，App 和键盘的  │
│ 配置是分开存的。这里可以用剪贴板把配置搬   │
│ 过去：本页写入 → 打开键盘 → 键盘内 ⚙️ →   │
│ 「从 App 导入」。                          │
└───────────────────────────────────────────┘
[ 写入配置到剪贴板 ]  PrimaryButton
   状态：✅ 已写入（3.2KB，2 个服务，不含 Key）
   ⚠️ API Key 默认不导出，请在键盘内单独填入
[ 清空剪贴板配置 ]  SecondaryButton
```
- 写入成功 Toast：「已写入，去键盘里点 ⚙️ › 从 App 导入」。
- `export` 失败的三种错误都要中文：没有 Provider / 编码失败 / 剪贴板不可用。
- 底部折叠「为什么这么麻烦？」展开一段 13pt 说明（免费账号限制）。

---

## 10. `AboutView`

- App 图标 96×96 圆角 22（`design/appicon/icon-1024.png` 缩放）。
- 名称「墨语」20 semibold，副标题「会 AI 的输入法」13 secondary，版本 1.0.0 (1)。
- 分组行：隐私政策（纯文本页，声明「无后端、无账号、数据不出本机」）/ 开源许可（本项目零第三方依赖）/ 反馈（复制邮箱）/ 特别说明（免费签名限制）。
- 底部一段 12pt tertiary：「本 App 不含任何统计 SDK，不会上传任何输入内容。」

---

## 11. 全局状态与文案基线

### 11.1 四类降级（QA 会逐个查）

| 场景 | 表现 |
|---|---|
| 无完全访问 | 键盘：AIBar 整条禁用 + 提示「开启完全访问后可用 AI ›」；App：键盘主页状态卡 ⚠️ |
| 未配置 Provider | 键盘：AIBar 禁用「还没有配置 AI 服务 · 点此设置」；App：设置页「AI 服务」行显示「未配置」红字 |
| 无网络 | 键盘：AIBar 禁用「网络未连接」；App：请求时 `ErrorBanner` + 恢复建议 |
| 服务端报错 | `ErrorBanner`：标题=`AIError.errorDescription`，副标题=`recoverySuggestion`，右侧「重试」 |

### 11.2 通用文案规则

1. 一句话说清「发生了什么」+ 一句「该怎么办」，不出现 HTTP 状态码裸奔（401 要说「API Key 无效或已过期」）。
2. 不用「Oops」「出错了」「Error」开头。
3. 数字带单位：「已等待 8 秒」不是「已等待 8」。
4. 按钮 2~4 个汉字：「保存」「取消」「重试」「去设置」「立即开启」。
5. 不使用感叹号（除非欢迎页一次）。

### 11.3 深色模式

- 全部使用 `Theme` 色彩（`Color(uiColor:)` + `UIColor(dynamicProvider:)`），**零硬编码 hex**。
- 分组背景：浅 `#F2F2F7` / 深 `#000000`；卡片：浅 `#FFFFFF` / 深 `#1C1C1E`。
- 分隔线：深色下用 `separator`（`#54545899`），不要用纯白 20%（会发灰）。
- 检查点：深色下 `warning.soft` / `danger.soft` 的卡片底不能变成「脏橘/脏红」——用 tokens 的值即可，不要自己调。

### 11.4 无障碍

- 所有可点元素 ≥44×44；图标纯装饰必须 `.accessibilityHidden(true)`。
- Toggle 行 VoiceOver：「剪贴板历史，开关，已关闭。关闭后键盘不读取剪贴板」。
- 流式输出在 VoiceOver 下**不要**逐字播报（`accessibilityLiveRegion` 只在完成后播报一次）。
- Dynamic Type：主 App 支持到 AX1；`ScrollView` 内容不裁剪。

---

## 12. 交付给 host-app-ui 的自检清单

- [ ] 12 个页面全部存在，命名与本文一致
- [ ] Onboarding **恰好 5 步**，第 3 步无「跳过」
- [ ] 安装指南 5 步含「GitHub Actions 云编译」+「iloader」+ 续签对比表
- [ ] 生图结果有「进度环 + 已等待 N 秒 + 预计 5–20 秒 + 取消」
- [ ] 所有颜色来自 `Theme`，字号来自 `Theme.font*`（主 App 可用 `typography.*` 新增项）
- [ ] 四类降级路径都有中文提示
- [ ] 深色模式无「脏色」
- [ ] 无第三方库、无网络图片
