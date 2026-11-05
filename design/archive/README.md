# design/ · 墨语（Moyu）设计交付目录

> **维护者**：design-lead（`docs/02 §1` 归 design-lead 独占）
> **版本**：v1.0 ｜ 2026-10-24
> **一句话**：这个目录是「设计 → SwiftUI 代码」的唯一中介。**如果某个界面元素的数值、颜色、圆角、动效不在这里，就说明它不该存在。**

---

## 0. 三条不可协商的声明（先读这一节）

> **① `tokens.json` 是唯一的色值真相源。**
> 仓库里任何地方需要颜色、字号、间距、圆角、尺寸、动效时长，都必须从 `tokens.json` 取值、经 `Theme.swift` 暴露后使用。
> **禁止**在 `.swift` 里写 `#RRGGBB` 字面量、`Color(hex:)`、`.system(size: 15)`、`.frame(width: 33)`。
> 当前 QA 实测：`hardcoded_hex = 0`、`magic_font = 0`（见 §4 校验命令），别打破它。
>
> **② 本目录里所有「数值」都以 `tokens.json` 为准，所有「几何施工图」以 `键盘布局规范.md` / `主App界面规范.md` 为准。**
> `视觉稿.html` 只是**观感参考**（它为了在浏览器里渲染，用 CSS 变量重写了一遍令牌；改 HTML 不等于改令牌）。
>
> **③ `design/03-设计与交互规范.md` 是 `docs/03-设计与交互规范.md` 的副本。**
> 权威版是 **`docs/03-设计与交互规范.md`**（因为 task-1 写入范围写的是 docs/03，用户与 `docs/02 §1` 也这么要求）。
> `design/03-...md` 这份存在的唯一原因：`scripts/qa/link_check.py:105` 与 `scripts/qa/consistency_check.py:414-415` 登记的路径是 `design/03-设计与交互规范.md`。
> **两份正文完全一致（diff 仅差顶部 5 行镜像声明 banner）**；**改内容只改 docs 那份**，然后重新生成本副本。

---

## 1. 先看这张表：我是谁，我该读什么

| 你是谁 | 必读（按顺序） | 可选 |
|---|---|---|
| **keyboard-ui**（`ios/AIKeyboardExtension/`） | ① `键盘布局规范.md` ② `组件库.md` §L0–L2 ③ `视觉稿.html` 第 01/02/03/06 屏 ④ **`04-AI对话与智能联想规范.md`**（旋钮 / 对话面板 / 智能联想，本次新增） | `03-设计与交互规范.md` §2/§7/§10 |
| **host-app-ui**（`ios/AIKeyboard/`） | ① `主App界面规范.md` ② `组件库.md` §L0/§L3 ③ `视觉稿.html` 第 04/05/07 屏 | `03-设计与交互规范.md` §2/§5/§11 |
| **ai-service**（`ios/Shared/Theme/Theme.swift`） | ① `tokens.json` ② `03-设计与交互规范.md` §15（变更流程） | `组件库.md` §L0 令牌映射 |
| **ios-skeleton**（工程/资源） | ① `appicon/图标方案.md` ② `appicon/generate_icon.py` | — |
| **qa-docs** | ① `03-设计与交互规范.md` §16 自检清单 | 全部（用于写 QA 报告） |
| **Lead / 新加入的人** | ① `视觉稿.html`（看观感）② 本文件 ③ `03-设计与交互规范.md` | — |

> `03-设计与交互规范.md` 有两份：**权威版在 `docs/03-设计与交互规范.md`**，`design/03-设计与交互规范.md` 是供 QA 脚本路径检查的镜像副本，内容一致。

---

## 2. 文件清单（共 8 件交付物 + 3 类支撑）

### 2.0 一眼看懂的数字

| 指标 | 数量 |
|---|---:|
| `design/` 下文件总数 | **19**（含 appicon/ 9 个） |
| `tokens.json` 叶子键 | **256**（9 个顶层组；color.light / color.dark 各 36，键集相同） |
| 组件契约 | **26 个 `public struct`**（其中 19 个是独立组件，7 个是子元素/条目类型）+ 12 个配套 `enum`；**另加 5 个已落地组件**（`KMChatKnob` / `KMKnobGlyph` / `ChatPanelView` / `ChatMessageListView` / `KMSuggestionChip`，见 `04-AI对话与智能联想规范.md` §2.8/§4.7） |
| 键盘页 / 态 | **8 个页面**（letters/numbers/symbols/emoji/aiPanel/result/settings/**aiChat**）× **17 个状态**（12 既有 + 5 新增） |
| 视觉稿 | **7 屏**（≥ 要求的 5 屏），共 **2 张**截图 |
| App 图标 | **1 套 6 个尺寸**（1024 / 180 / 120 / 80 / 60 / 40） |
| 设计文档 | 5 份专项 md（键盘布局 / 主App界面 / 组件库 / **AI对话与智能联想** / 图标方案）+ 1 份总纲（03）+ 本索引 |

### 2.1 核心交付（task-1 要求的 6 件）

| # | 文件 | 大小 | 给谁用 | 什么时候用 |
|---:|---|---:|---|---|
| 1 | **`tokens.json`** | 8.2 KB | ai-service、两个 UI | 写任何颜色/字号/间距/尺寸前，**先查这里**。这是唯一可机读的令牌源 |
| 2 | **`键盘布局规范.md`** | 29 KB | keyboard-ui | 实现键盘前通读；每个数字都能用文中的公式复算 |
| 3 | **`主App界面规范.md`** | 27 KB | host-app-ui | 实现主 App 每屏前查对应章节 |
| 4 | **`组件库.md`** | 37 KB | 两个 UI | 写任何 `View` 前先查有没有现成组件；命名必须一致 |
| 5 | **`视觉稿.html`** | 48 KB | 所有人 | 看观感、对比稿；也可当作像素级参考 |
| 6 | **`appicon/图标方案.md`** + `appicon/generate_icon.py` | 12 KB + 10 KB | ios-skeleton | 生成 App 图标时；脚本直接跑就能出图 |
| 7 | **`04-AI对话与智能联想规范.md`** | 37 KB | keyboard-ui、ai-service | **本次新增**：旋钮 / 全屏 AI 对话面板 / AI 智能联想。含精确坐标、状态机、15 个 sizing + 3 个 motion 令牌增量、P0 验收清单 |
| 8 | **`03-设计与交互规范.md`**（镜像） | 39 KB | 所有人 | 设计系统总纲；权威版是 `docs/03-设计与交互规范.md` |

### 2.2 支撑文件

| 文件 | 说明 |
|---|---|
| **`03-设计与交互规范.md`**（镜像） | `docs/03` 的副本，仅供 QA 脚本路径检查；**改内容请改 docs 那份** |
| **`04-AI对话与智能联想规范.md`**（镜像） | `docs/07` 的副本（`docs/04` 已被《安装与续签指南》占用）；正文逐字相同，权威版在 design |
| **`preview-overview.png`** | 视觉稿全景截图（3020×930），7 屏并排 |
| **`preview-keyboard.png`** | 键盘单屏特写（2100×900） |
| `appicon/icon-1024.png` | App 图标主尺寸（1024×1024，iOS 会自动裁圆角） |
| `appicon/icon-{180,120,80,60,40}.png` | 小尺寸预览，用于检查可读性 |

### 2.3 `tokens.json` 顶层键（校验时打印的就是这些）

```
meta / color / typography / spacing / radius / sizing / motion / shadow / material
```

- `color.light` 与 `color.dark` 各 **36 键**，键集完全相同。
- `docs/02 §5` 要求的 **20 个颜色键、8 个排版项、6 间距、5 圆角、9 sizing、4 motion、2 shadow 逐字一致，零变更**。
- 其余为扩展键（只增不改），清单见 `docs/03-设计与交互规范.md` §15.2。
- 2026-10-25 增量（`04-AI对话与智能联想规范.md` §6）：`sizing` **38 → 53**（`aiChat*` 11 键 + `sugChip*` 4 键）、`motion` **11 → 14**（`suggestDebounce` / `knobPress` / `knobActiveFade`）。**所有新值都已存在于 `Theme.swift`**，所以 `consistency_check.py` 仍全绿。

---

## 3. 怎么用：三条工作流

### 3.1 「我要实现一个界面」

```
1. 在 视觉稿.html 里找到对应屏，建立观感
2. 在 键盘布局规范.md / 主App界面规范.md 找到那一屏的施工图
3. 在 组件库.md 里找到要用组件（不要自己造）
4. 组件需要的数值 → 查 tokens.json → 用 Theme.XXX 取值
5. 写完跑 python scripts/qa/consistency_check.py 确认 P0=0 P1=0
6. 过 docs/03 §16 的 P0 自检清单
```

**绝对不要做的事**：
- 在 View 里写 `Color(hex: "#0A84FF")` 或 `.foregroundColor(Color(red:...))` → 用 `Theme.accent`
- 用 `.system(size: 15)` 直接写字号 → 用 `Theme.fontBody`
- 用 `.frame(width: 33)` 写死尺寸 → 用 `Theme.Sizing.letterKeyWidth`
- 用 `.cornerRadius(16)` → 用 `.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))`
- 用 `.ultraThinMaterial` 直接贴 → 用 `GlassSurface(level:)`
- 用 `.rect(cornerRadius:)` / `.symbolEffect` / `.scrollTargetBehavior` → 都是 iOS 17 API，**部署目标是 16.0**

### 3.2 「我要看视觉稿 / 重新截图」

```powershell
# 全景 7 屏（3020×930）
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$html = (Resolve-Path 'design\视觉稿.html').Path
$out  = (Resolve-Path 'design').Path + '\preview-overview.png'
& $edge --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 `
        --screenshot="$out" --window-size=3020,930 "file:///$($html -replace '\\','/')"

# 键盘单屏（2100×900）
$out2 = (Resolve-Path 'design').Path + '\preview-keyboard.png'
& $edge --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 `
        --screenshot="$out2" --window-size=2100,900 "file:///$($html -replace '\\','/')"
```

> 视觉稿是**单文件、零外部依赖**（无 CDN、无网络字体、无远程图片、无外部 JS），断网也能打开；所有动效写成 `animation:none` 静态态，所以截图不会截到动画中间帧。
> 字体栈 `-apple-system, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif`，Windows 下自动落到微软雅黑，中文不会出豆腐块。
> **SF Symbols 在 HTML 里不可用**，全部用 Unicode 几何符号 / emoji 占位（`⇧ ⌫ 🌐 🙂 ⏎ ✨ 💬 🧠 🎨 ⚙️ ↑ ⌄ › ✕ ↻ ＋`）。真实 App 里主 App 域用 SF Symbols，键盘域用 emoji + 文字，映射表见 `组件库.md` §L0 `IconGlyph`。

### 3.3 「我要重新生成 App 图标」

```powershell
& python design\appicon\generate_icon.py
```

输出 `design/appicon/icon-1024.png` 及 `icon-180/120/80/60/40.png`。
依赖：Python 3.13 + Pillow（已装）+ 系统字体 `msyhbd.ttc`（脚本带字体探测链，缺失会自动降级）。
设计说明、配色 hex、几何规格、小尺寸验收见 `appicon/图标方案.md`。

**接入 Xcode**：
```powershell
python scripts\make_appicon.py --force
```
该脚本会自动探测 `design/appicon/icon-1024.png` 并复制进 `ios/Resources/Assets.xcassets/AppIcon.appiconset/`。
> ⚠️ 如果 `ios/.../AppIcon-1024.png` 与 `design/appicon/icon-1024.png` 不一致，说明是 design 稿落盘前跑的兜底版 —— **重跑一次 `--force` 即可**，不要改脚本。

---

## 4. 视觉稿的 7 屏（找东西用）

| 屏 | 标题 | 内容要点 |
|---:|---|---|
| 01 | 键盘 · 打字态 | 浅色 258pt：候选栏 44 + AI 工具条 40 + 26 键 174；首候选加粗、分页点 |
| 02 | 键盘 · AI 面板 | 展开 426pt：上下文预览 + 胶囊输入框 + 5 种语气 + 快捷短语 + 生成按钮 |
| 03 | 键盘 · AI 结果卡 | 展开 438pt：流式打字机 + 插入/复制/编辑/重试/关闭 |
| 04 | 主 App · AI 服务 | Provider 列表（DeepSeek 已连接 / 通义未测试 / Kimi 失败）+ 默认设置 + 签名剩余天数 |
| 05 | 主 App · AI 试验场 | **生图绘制中**：进度环 + 「已等待 8 秒 · 预计 5–20 秒」+ 取消按钮 |
| 06 | 键盘 · 深色 | 深色令牌全套，候选栏带序号 |
| 07 | 主 App · 设置 | AI / 键盘 / 隐私 / 支持 四组 |

---

## 5. 常见问题

**Q：`tokens.json` 里没有我要的值，能自己加吗？**
A：先看 `docs/03` §6 刻度表——大概率是应该用 `md(8)` 而不是 10。确实需要新值，走 `docs/03` §15.4 的流程（改 tokens → 记账 → 通知 ai-service 改 Theme.swift），**不要**在代码里写局部常量。

**Q：设计和 `docs/02` 冲突了怎么办？**
A：`docs/02` 的令牌键名与基线数值**优先级最高**，`tokens.json` 已与之逐字一致。如果发现新的冲突，**先报 Lead**，不要自己改 `docs/01`、`docs/02`（那不是 design-lead 的写入范围）。

**Q：为什么 26 键竖屏行高是 39，而 `sizing.keyHeight` 是 42？**
A：258 = 44 + 40 + 174，字母区 174 放 4 行 + 3×6 行距 → 每行只能 39。42 是契约里的「键帽标称高」，用于 9 键/横屏/主 App 的键帽示意，两个值都合法并存。详见 `键盘布局规范.md` §1.1。

**Q：为什么行 2 左右各留 19.5pt，不把键拉宽填满？**
A：iOS 原生键盘行 2 也是窄的。拉宽会让行 1（33）和行 2（34.5）键宽不一致，视觉上像错位。这是刻意的设计选择，见 `键盘布局规范.md` §2.3。

**Q：AI 结果卡为什么不用普通的 loading 圈？**
A：生图走的是即梦/通义万相，**异步 5–20 秒**。无限转圈会让用户以为卡死。必须显示「进度环 + 已等待 N 秒 + 预计 5–20 秒 + 取消按钮」，见 `组件库.md` `AIResultCard` 的 `.imageGenerating` 态。

**Q：截图我看不到怎么办？**
A：`preview-overview.png` 是 3020×930 的长图，直接双击打开即可（不需要服务器）。源码是 `视觉稿.html`，浏览器直接打开也行（零依赖）。

---

## 6. 变更记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.2 | 2026-10-25 | `04-AI对话与智能联想规范.md` 与 `docs/07` 镜像同步升到 **v1.1**：§2.8 / §4.7 / §9 由「待实现清单」改写为「**已落地清单**」（旋钮、对话面板、联想三块的代码已于本日全部合入 `ios/AIKeyboardExtension/`，新增 `KMChatKnob.swift`、`ChatPanelView.swift`、`ChatMessageListView.swift`、`KMSuggestionChips.swift`、`KeyboardViewModel+Chat/Suggest.swift`）；记录两处「实现优于设计」的偏差与一处待补令牌（`aiChatKnobLandscapeSize`）。全文复查：`design/` 7 份产物 MD 与 HTML **旧签名工具名命中 0**（签名/安装工具统一为 **iloader**）。 |
| v1.1 | 2026-10-25 | 新增 `04-AI对话与智能联想规范.md`（权威版）+ `docs/07-AI对话与智能联想规范.md`（镜像）：AI 对话旋钮（44 命中 / 34 视觉圆，五态）、全场对话面板（438 = 40+180+44+174，保留 174 键区）、AI 智能联想（3 条 ≤12 字，防抖 0.35s，失败静默）。`tokens.json` 由 238 → **256** 叶子：sizing +15、motion +3，**零新增高度令牌、零新增 hex**，QA 仍 `P0=0 P1=0 P2=0`。 |
| v1.0 | 2026-10-24 | 初版：tokens.json（238 leaves / 9 顶层组）、键盘布局规范、主App界面规范、组件库、视觉稿 + 2 张截图、App 图标方案 + 脚本 + 6 尺寸 PNG、docs/03 设计与交互规范（+ design 镜像）、本索引。 |
