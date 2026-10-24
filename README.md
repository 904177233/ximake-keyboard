# 墨语 · Moyu Keyboard

> **会 AI 的 iOS 输入法**：打字、润色、扩写、翻译、生图、生成回复、AI 对话、智能联想，全在键盘里完成，一键上屏。
>
> 纯本地 · 零后端 · 不收集任何数据 · 只需要一台 Windows 电脑 + 一个免费 Apple ID。

---

## 一句话介绍

**墨语是一个给自己用的 iOS 中文拼音输入法，内置 7 个 AI 能力，AI 结果直接插入你正在打字的输入框。**

它由两部分组成：一个系统级键盘扩展（`AIKeyboardExtension`）负责打字与 AI 交互，一个宿主 App（`AIKeyboard`）负责配置与试验。所有 AI 请求都从你手机**直连**你自己填的服务商，不经过任何中转服务器。

---

## 卖点 6 条

| # | 卖点 | 说明 |
|---|---|---|
| 1 | **AI 就在键盘里** | 润色 / 扩写 / 翻译 / 回复建议 / 生图 / **AI 对话**，选中文字点一下，流式输出后**直接插入输入框**，全程不离开当前 App |
| 2 | **导航栏里的 AI 对话旋钮** | 候选栏右侧一枚 34pt 的旋钮（只有图标没有文字），点一下**整块键盘直接变成 AI 对话界面**——能聊、能追问、结果一键上屏。不打断你正在打的字 |
| 3 | **非传统联想词** | 不是「词库里的下一个词」，而是**读你宿主 App 里已经打出的前文**，猜你下一句想说什么，最多 3 条胶囊，点一下上屏。本地规则 0.2ms 兜底 + AI 深度联想，失败完全静默 |
| 4 | **任意模型随便接** | 只要服务商兼容 OpenAI / Anthropic / Gemini 协议就能用。内置 9 家国内预设（DeepSeek、通义、Kimi、智谱、豆包、硅基流动等），也能填中转站 |
| 5 | **Key 只存在你手机里** | API Key 存 iOS **Keychain**，App 内可见可控。**无账号、无云同步、无遥测、无统计**，代码可自查 |
| 6 | **零成本，Windows 也能装** | 没有 $99 开发者账号？GitHub Actions 免费云编译 + Windows 上 iloader 签名安装，全程不需要 Mac。7 天续签 5 分钟搞定 |

---

## 目录结构

```text
输入法/
├── README.md                     ← 你正在看的这页
├── .gitignore
├── .github/
│   └── workflows/
│       └── build.yml             ← GitHub Actions：云端 macOS 编译出未签名 IPA
│
├── docs/                         ← 产品与交付文档
│   ├── 00-待确认问题.md           ← 等你拍板的问题清单（含默认假设）
│   ├── 01-产品需求与方案.md       ← 做什么、不做什么、验收标准
│   ├── 02-技术架构与接口契约.md   ← 唯一真相源：目录归属、API 签名、设计令牌
│   ├── 03-设计与交互规范.md       ← 逐屏视觉/交互规范（与 design/ 同源）
│   ├── 04-安装与续签指南.md       ← ⭐ Windows 用户照这个做
│   ├── 05-常见问题.md             ← 28 个高频疑问
│   ├── 06-QA报告.md               ← QA 静态检查报告（阶段二产出）
│   ├── 07-AI对话与智能联想规范.md ← AI 对话旋钮 + 非传统联想的设计规范
│   └── ios/
│       └── README-构建.md         ← 工程生成器与 CI 的细节说明
│
├── design/                       ← 视觉设计
│   ├── tokens.json               ← 设计令牌（颜色/字号/间距/圆角/动效/尺寸）
│   ├── 组件库.md
│   ├── 键盘布局规范.md
│   ├── 主App界面规范.md
│   ├── 04-AI对话与智能联想规范.md ← 旋钮 / 对话面板 / 联想胶囊的施工图
│   ├── 视觉稿.html               ← 浏览器直接打开看效果
│   ├── preview-keyboard.png
│   ├── preview-overview.png
│   └── appicon/                  ← 图标方案与各尺寸 PNG
│
├── ios/                          ← 全部 Swift 代码
│   ├── project.yml               ← 人类可读的工程声明（参考用，非构建必需）
│   │
│   ├── AIKeyboard.xcodeproj/     ← 由 scripts/gen_xcodeproj.py 生成
│   │   ├── project.pbxproj
│   │   └── xcshareddata/xcschemes/
│   │       ├── AIKeyboard.xcscheme
│   │       └── AIKeyboardExtension.xcscheme
│   │
│   ├── AIKeyboard/               ← 宿主 App
│   │   ├── App/                  ← 入口、RootView、AppState
│   │   ├── Components/           ← 通用组件（按钮/卡片/Toast/AI 结果卡…）
│   │   ├── Main/                 ← 主界面、设置页
│   │   ├── Onboarding/           ← 首次引导
│   │   ├── Playground/           ← AI 试验场
│   │   ├── Settings/             ← 服务商编辑、Prompt 库、外观、隐私、诊断…
│   │   ├── Guide/                ← 安装与续签引导
│   │   └── Support/              ← 跨模块桥接
│   │
│   ├── AIKeyboardExtension/      ← 键盘扩展（App Extension）
│   │   ├── Theme/                ← 键盘专属布局常量
│   │   ├── ViewModel/            ← KeyboardViewModel（含 +AI/+Chat/+Suggest/+Input 分片）
│   │   ├── Views/                ← 键盘视图（含 KMChatKnob / ChatPanelView / KMSuggestionChips）
│   │   └── KeyboardViewController.swift
│   │
│   ├── Config/                   ← ⚠️ 改 Bundle ID / 签名就改这里
│   │   ├── Base.xcconfig         ← 公共构建设置
│   │   ├── App.xcconfig          ← 宿主 App：Bundle ID、Info.plist、entitlements
│   │   ├── Extension.xcconfig    ← 键盘扩展：Bundle ID 必须是 App + ".keyboard"
│   │   ├── App-Info.plist
│   │   ├── Extension-Info.plist  ← NSExtensionPointIdentifier = keyboard-service
│   │   ├── AIKeyboard.entitlements
│   │   ├── AIKeyboardExtension.entitlements
│   │   └── AIKeyboard.entitlements.appgroup.sample  ← 有开发者账号才用
│   │
│   ├── Shared/                   ← 两个 target 共享
│   │   ├── Models/               ← 数据契约（AIProviderConfig、ChatDelta…）
│   │   ├── Networking/           ← LLM 客户端、SSE 解析、图片客户端
│   │   ├── Storage/              ← ConfigStore、KeychainStore、PasteboardBridge
│   │   ├── Prompts/               ← Prompt 模板与内置库
│   │   ├── IMECore/              ← 拼音引擎、词库、用户学习
│   │   ├── Theme/                ← Theme.swift（设计令牌的代码实现）
│   │   └── dict/                 ← base_dict.tsv、phrases.tsv、dict_meta.json（bundle 根 `dict/`；禁止叫 Resources）
│   │
│   └── Resources/Assets.xcassets ← App 图标与强调色
│
├── scripts/                      ← 构建与校验脚本（Python 标准库，零依赖）
│   ├── gen_xcodeproj.py          ← ⭐ 按磁盘真实文件重新生成 pbxproj
│   ├── validate_project.py       ← 校验生成的工程结构（85+ 项）
│   ├── make_appicon.py           ← 生成 App 图标
│   ├── finalize.ps1              ← ⭐ 一键收尾闸门（Windows / PowerShell）
│   ├── finalize.sh               ← 一键收尾闸门（macOS / CI，等价）
│   └── qa/
│       ├── qa_common.py          ← QA 公共库（Swift 词法状态机等）
│       ├── static_check.py       ← Swift 静态检查（括号/分层/符号/编码/文案）
│       ├── project_check.py      ← pbxproj 结构校验（target/引用/文件归属）
│       ├── consistency_check.py  ← 设计令牌 ↔ Theme.swift 一致性
│       ├── link_check.py         ← 文档路径死链校验
│       └── final_acceptance.py   ← ⭐ 最终验收：串起六闸门 + GO/NO-GO 结论
│
└── tools/dict/                   ← 词库构建工具链
    ├── build_dict.py
    ├── phrase_pairs.py
    ├── gen_swift_syllables.py
    ├── symbol_map.py
    └── syllable_table.py
```

---

## 5 分钟上手（Windows 用户）

> **完整版见 [`docs/04-安装与续签指南.md`](docs/04-安装与续签指南.md)**（含 16 条报错对照表）。下面是压缩版。

| 步骤 | 做什么 | 大约耗时 |
|---|---|---|
| **1** | 把代码推到 GitHub 仓库（**Public / Private 都行**，用 GitHub Desktop 拖进去点 Publish 即可，不用敲命令） | 10 分钟（含注册） |
| **2** | 打开仓库页 → **Actions** → 左侧 `Build Unsigned IPA` → 等绿勾（云端 macOS 自动编译，约 **1～3 分钟**）→ 底部 **Artifacts** 下载 `AIKeyboard-unsigned-ipa` → 解压出 `AIKeyboard-unsigned.ipa`（约 3 MB） | 1～3 分钟 |
| **3** | **【必做】验 IPA**：改成 `.zip` 解开，确认存在 `Payload\AIKeyboard.app\PlugIns\AIKeyboardExtension.appex`（没有这个，键盘永远装不上） | 1 分钟 |
| **4** | Windows 装 **iloader**（[GitHub nab138/iloader](https://github.com/nab138/iloader) 下载 `iloader-windows-x64.exe`，静默装）→ 插手机 → 填 Apple ID / 密码 → 2FA 验证码 → **Import IPA** 选刚下的包 → **Sign & Install App** | 10 分钟 |
| **5** | iPhone：设置 › 通用 › **VPN与设备管理** → 信任你的 Apple ID | 1 分钟 |
| **6** | 设置 › 通用 › **键盘 › 键盘** → **添加新键盘** → 墨语 → 完成 → **点「墨语」那一行** → 开 **允许完全访问**（AI 的生死线） | 2 分钟 |
| **7** | 打开「墨语」App → 配服务商（填 API Key）→ 点 **同步到键盘** → 键盘 ⚙️ → **从剪贴板导入** | 3 分钟 |

> **为什么是 iloader 而不是 Sideloadly**：Sideloadly 0.71.1 的 Apple ID 登录走的是 Apple 早已下线的 `/IDMSWebAuth/clientDAW.cgi` 端点，无论怎么配都返回 `Login failed: 404`（已实测排除代理/证书/UA/路径四类原因）。iloader 用现代登录 + 远程 Anisette，可正常签名。详见 [`docs/04-安装与续签指南.md`](docs/04-安装与续签指南.md) §4。

**然后每 7 天**：重复第 4 步（IPA 不用重下）即可。清单见 [`docs/04-安装与续签指南.md`](docs/04-安装与续签指南.md) §9.3。

---

## 架构图

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                              iPhone (iOS 16+)                            │
│                                                                          │
│  ┌────────────────────────────┐        ┌───────────────────────────────┐ │
│  │  墨语 App（宿主）           │        │  墨语键盘（App Extension）     │ │
│  │  AIKeyboard.app            │        │  AIKeyboardExtension.appex    │ │
│  │                            │        │                               │ │
│  │  · 引导 / 设置              │        │  · 26 键 & 9 键输入            │ │
│  │  · 服务商管理（增删改测）    │        │  · 候选栏 / 数字符号 / Emoji   │ │
│  │  · Prompt 模板库            │        │  · AI 工具条                  │ │
│  │  · AI 试验场（先试再用）     │        │  · 流式结果卡片                │ │
│  │  · 诊断页（连通性自检）      │        │  · AI 对话旋钮 → 全屏对话界面   │ │
│  │                            │        │  · 非传统联想胶囊（读前文猜下一句）│ │
│  └────────────┬───────────────┘        └───────────────┬───────────────┘ │
│               │                                        │                 │
│               │        ┌───────────────────────────────┴───────┐         │
│               └────────┤        Shared（编译进两个 target）      │         │
│                        │  Models · Networking · Storage        │         │
│                        │  Prompts · IMECore · Theme            │         │
│                        └───┬──────────────┬──────────────┬─────┘         │
│                            │              │              │               │
│                    ┌───────▼──────┐ ┌─────▼──────┐ ┌─────▼───────────┐   │
│                    │  Keychain    │ │UserDefaults│ │ 具名剪贴板       │   │
│                    │ （API Key）   │ │（配置快照） │ │ moyu.config     │   │
│                    └──────────────┘ └────────────┘ └─────────────────┘   │
│                                                     ▲                    │
│                                        「同步到键盘」按钮 │               │
└─────────────────────────────────────────────────────┼────────────────────┘
                                                      │
                          ┌───────────────────────────▼──────────────────┐
                          │   AI 服务商（你自选，直连，不经中转）           │
                          │   OpenAI · DeepSeek · 通义 · Kimi · GLM · …   │
                          │   生图：即梦 / 豆包 / 通义万相                 │
                          └──────────────────────────────────────────────┘
```

### 四个关键设计决定

| 决定 | 为什么 |
|---|---|
| **无 App Group（免费签名装不了）** | App 与键盘各自独立的 `UserDefaults`。配置靠「同步到键盘」把 JSON 写进**具名剪贴板**，键盘从剪贴板读。这比 hack entitlements 稳，也不会因为描述文件不匹配而崩溃 |
| **API Key 从不进剪贴板** | `PasteboardBridge.export(includeAPIKeys: false)` 默认剔除 Key。键盘需要用 Key 时在键盘自己的设置页里单独填一次（因为共享 Keychain 也需要 App Group） |
| **AI 状态机全在 `@MainActor`** | 键盘扩展只有 40–60MB 内存额度，流式输出必须一次只有一个在跑，取消要能立刻断流，否则点两次就崩 |
| **对话面板保留 174pt 键区** | iOS 扩展里无法可靠唤起系统键盘，砍掉键区就等于「只能聊不能打」。复用 `.result` 已有的 +180 高度（438），**零新增高度令牌**，横屏按 §3.11 走 32/108/44/156 = 340 |

---

## 技术栈

| 层 | 选型 | 备注 |
|---|---|---|
| 语言 | **Swift 5.0** | `SWIFT_VERSION = 5.0` |
| UI | **SwiftUI**（键盘用 UIKit 容器 + SwiftUI 视图） | 零第三方 UI 库 |
| 最低系统 | **iOS 16.0** | `IPHONEOS_DEPLOYMENT_TARGET = 16.0` |
| 架构 | MVVM + 协议注入 | `@MainActor` ViewModel |
| 网络 | **URLSession + 自写 SSE 解析** | 不依赖 Alamofire |
| 存储 | **Keychain**（Key）+ **UserDefaults**（配置）+ **剪贴板**（跨进程传递） | 无数据库 |
| 构建 | **xcodebuild** via GitHub Actions | `macos-14` runner，产出未签名 IPA |
| 工程生成 | **Python 标准库**脚本 | `scripts/gen_xcodeproj.py`（作者只有 Windows） |
| 签名 | **iloader**（免费 Apple ID） | 7 天一次；Sideloadly 因 Apple 下线老端点已不可用 |
| 依赖 | **零**（无 SPM / CocoaPods / Carthage） | 全过程无 `pod install` |

---

## 隐私说明

| 项目 | 实际情况 |
|---|---|
| **API Key 存哪里** | iOS **Keychain**（`service = com.moyu.apikey`），App 内「服务商」页可随时查看 / 删除 |
| **会不会上传我的聊天** | 只上传你**主动点 AI 按钮时**选中 / 输入的那段文字，直接发给你自己配置的服务商。**没有任何墨语服务器** |
| **有没有遥测 / 统计** | **没有**。无友盟、无 Firebase、无 Sentry、无埋点 |
| **有没有账号** | **没有**。不注册、不登录、不读取通讯录 |
| **剪贴板怎么用** | 只在你点「同步到键盘」时写一次具名剪贴板 `com.moyu.config`，且**默认不含 API Key**。剪贴板历史功能默认关闭 |
| **完全访问权限** | 只用于**联网调 AI** 和**读剪贴板配置**。代码可自行审计 |
| **第三方 SDK** | **零**。所有依赖都是 Apple 系统框架 |

---

## 已知限制

| # | 限制 | 影响 | 缓解 |
|---|---|---|---|
| 1 | **不能在 Windows 上编译** | 必须走 GitHub Actions 云编译（免费，等 1～3 分钟）或借 Mac | 见 [`docs/04-安装与续签指南.md`](docs/04-安装与续签指南.md) 路线 A |
| 2 | **免费签名 7 天过期** | 每 7 天要重新签名安装一次，否则 App 闪退（数据不丢） | 续签清单，5 分钟搞定 |
| 3 | **免费账号无 App Group** | App 与键盘配置不共享，要手动「同步到键盘」 | 具名剪贴板方案 |
| 4 | **键盘扩展内存 ~40–60MB** | 大词库不能全量加载，生图大图要压缩 | 精简词库 + 流式输出 |
| 5 | **生图结果不能直接插入输入框** | `UITextDocumentProxy` 协议只支持文字，不支持图片（全行业 AI 键盘共同限制） | 键盘内「复制图片」后在聊天框长按粘贴；或在 App 里「保存到相册」再用宿主 App 的图片按钮发 |
| 6 | **不支持双拼 / 五笔 / 语音 / 手写** | 只做拼音（全拼 / 简拼 / 混拼，**支持模糊音**：zh/z、ch/c、sh/s、in/ing、l/n 等 9 组，可在键盘设置里开关） | 非目标范围 |
| 7 | **iPad 未做专门优化** | 能用但布局是手机版拉伸 | 主要面向 iPhone |
| 8 | **字体与键盘高度不可改** | 设计上固定 | 可改 `design/tokens.json` 后重编译 |
| 9 | **iOS 16.0 以下装不了** | 老设备不支持 | 系统要求 |
| 10 | **免费账号最多 3 个 App ID** | 装过 3 个自签 App 就满了 | 卸载不用的自签 App |
| 11 | **无云同步、无多设备** | 换手机要重新配置 | 用「配置导出」手抄 |
| 12 | **不上架 App Store** | 仅个人自用 | 见下方免责声明 |
| 13 | **iOS 27 不允许 bundle 根下出现 `Resources` 这一层目录** | 词库若多套一层 `Resources`，装包时设备会报 `IXErrorDomain Code=13 Missing bundle ID`，看起来像签名坏了 | 词库直接放 bundle 根 `dict/`；CI 第 6 步 `Preflight - dictionary layout` 会拦 |

---

## 免责声明

1. 本项目是**个人学习与自用**项目，**不上架 App Store**，不提供任何商业服务。
2. 使用本项目需要**你自己**拥有合规的 AI 服务商账号与 API Key，产生的费用由你自行承担。
3. 本项目**不收集、不存储、不转发**任何用户数据。但 AI 请求的内容会发送给**你选择的第三方服务商**，其隐私政策由该服务商负责。
4. 自签名安装（Sideloadly / AltStore）属于 Apple 允许的开发者调试范畴。**请勿用于分发或商业用途**，由此产生的账号风险由使用者自负。
5. 输入法涉及隐私敏感权限（完全访问）。**代码完全公开可审计**，但请自行评估风险后使用。
6. AI 生成的内容可能不准确。**不要**用它处理医疗、法律、金融等专业决策。
7. 本项目与 Apple Inc. 无任何关联。Apple、iPhone、iOS、Xcode 是 Apple Inc. 的商标。

---

## 开发者

### ⚠️ 改代码后必做：重跑工程生成器

> **任何对 `ios/Shared/`、`ios/AIKeyboard/`、`ios/AIKeyboardExtension/` 里 `.swift` 文件的增删改，之后都必须重跑 `python scripts/gen_xcodeproj.py`。**
>
> `ios/AIKeyboard.xcodeproj/project.pbxproj` 是脚本按磁盘真实文件树**生成**的，**不是手写的**。不重跑，新增的文件就不会被编进 target（表现是 Xcode / CI 报 `cannot find 'XXX' in scope`，或 `project_check.py` 报 `PBX-UNTRACKED-SOURCE`）。

**一条命令跑完全部闸门**（生成 + 结构校验 + QA 三件套）：

| 系统 | 命令 |
|---|---|
| **Windows** | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/finalize.ps1` |
| **macOS / CI** | `bash scripts/finalize.sh` |

`finalize.ps1` 依次跑 6 个闸门，任一失败立刻中止：`scripts/gen_xcodeproj.py` → `scripts/validate_project.py` → `scripts/qa/project_check.py` → `scripts/qa/static_check.py` → `scripts/qa/consistency_check.py` → `scripts/lead/pbxproj_plist_check.py`。

**不要手改 `project.pbxproj`** —— 下次重跑会整个覆盖，你的修改会丢失。

> 背景：项目并行开发期间发生过多次「新 `.swift` 没进 pbxproj → `project_check` 报 P0」的抖动，全部是**忘了重跑生成器**导致的，不是脚本 bug。所以你看到的 P0 里如果有 `PBX-UNTRACKED-SOURCE` / `PBX-SHARED-NOT-IN-*`，第一反应应该是跑 `finalize`，而不是改代码。

### 发布前自检：一条命令出 GO / NO-GO

```powershell
python scripts\qa\final_acceptance.py
```

它按顺序跑**六个闸门**（gen 同步 → validate_project → project_check → static_check → consistency_check → link_check），汇总成一张表并给出明确结论：

| 退出码 | 结论 | 含义 |
|---|---|---|
| `0` | **GO** 🟢 | 六闸门 P0 = 0 且 P1 = 0 |
| `1` | **CONDITIONAL GO** 🟡 | 无 P0，但有 P1，需逐条签收 |
| `2` | **NO-GO** 🔴 | 存在 P0，停止发布 |
| `3` | 内部错误 | 某个脚本跑不起来 |

加 `--md docs/06-QA报告.md --inject` 可把结果自动回填到 QA 报告的「最终验收」章节。完整判定标准见 [`docs/06-QA报告.md`](docs/06-QA报告.md) §9.2。

> ⚠️ **静态检查全绿 ≠ 能编译** —— 这个判断已被现实验证：六闸门全绿的情况下，真 `xcodebuild` 仍然报了 **14 个硬错误**（外加 1 个 pbxproj 词法错误让工程直接打不开）。逐条留档见 [`docs/06-QA报告.md`](docs/06-QA报告.md) §9.2b，那是本项目最有价值的一页。
>
> ✅ **当前状态**：CI 已在 `macos-14` 上真实跑通（run [40131175295](https://github.com/904177233/ximake-keyboard/actions/runs/40131175295)，18 步全绿，产出 3.01 MB 未签名 IPA，键盘扩展与词库都已正确打进 `PlugIns/`），并且**已经在真机上装成功、App 能打开**。真机踩到的两个坑（iOS 27 拒收 bundle 根 `Resources/` 目录、`applyHeight` 无限递归闪退）都已修复并留档。

### 工程与构建

| 我想… | 看这里 |
|---|---|
| 打开工程 / 在 Xcode 里编译 / 装真机 / pbxproj 打不开的兜底方案 | [`docs/ios/README-构建.md`](docs/ios/README-构建.md) |
| 没有 Mac，云端构建出 IPA | [`.github/workflows/build.yml`](.github/workflows/build.yml) —— 手动 `Run workflow` → Artifacts 下载 `AIKeyboard-unsigned-ipa`（保留 7 天） |
| 改 Bundle ID / Team / 版本号 | [`ios/Config/README.md`](ios/Config/README.md)（要改 `ios/Config/*.xcconfig`，别在 Xcode 面板改，会被生成器覆盖） |
| QA 脚本怎么跑、各检查码什么意思 | [`docs/06-QA报告.md`](docs/06-QA报告.md) §12 |

---

## 文档索引

| 文档 | 内容 | 什么时候看 |
|---|---|---|
| [`docs/00-待确认问题.md`](docs/00-待确认问题.md) | 需要你拍板的问题 + 默认假设 | 想改需求时 |
| [`docs/01-产品需求与方案.md`](docs/01-产品需求与方案.md) | 产品目标、功能清单、验收标准 | 想知道「做了什么」 |
| [`docs/02-技术架构与接口契约.md`](docs/02-技术架构与接口契约.md) | 目录归属、API 签名、数据契约、设计令牌 | 想改代码时 |
| [`docs/03-设计与交互规范.md`](docs/03-设计与交互规范.md) | 逐屏视觉/交互规范、组件库、状态矩阵 | 想改界面时 |
| [`docs/04-安装与续签指南.md`](docs/04-安装与续签指南.md) | **Windows 装到 iPhone 的完整步骤 + 16 条报错对照 + 7 天续签** | 第一次装 / 装不上 |
| [`docs/05-常见问题.md`](docs/05-常见问题.md) | 28 个高频疑问（安全、费用、功能边界…） | 有疑问时 |
| [`docs/06-QA报告.md`](docs/06-QA报告.md) | 静态检查结果、P0/P1/P2 问题清单、真编译踩的 14 个坑 | 想知道代码质量 |
| [`docs/07-AI对话与智能联想规范.md`](docs/07-AI对话与智能联想规范.md) | AI 对话旋钮、全屏对话面板、非传统联想胶囊的施工图 | 想改对话/联想功能 |
| [`docs/ios/README-构建.md`](docs/ios/README-构建.md) | 工程生成器原理、CI 细节 | 想改构建流程 |
| [`design/tokens.json`](design/tokens.json) | 设计令牌（颜色 / 字号 / 间距 / 动效，256 个叶子） | 想改配色 / 尺寸 |
| [`design/键盘布局规范.md`](design/键盘布局规范.md) | 26 键 / 9 键布局与尺寸 | 想改键盘布局 |
| [`design/04-AI对话与智能联想规范.md`](design/04-AI对话与智能联想规范.md) | 旋钮 / 对话面板 / 联想胶囊的逐像素施工图（与 docs/07 同源） | 想改对话页 |
| [`ios/Config/README.md`](ios/Config/README.md) | 改 Bundle ID / Team / 版本号 | 签名前必读 |

---

## 许可

**个人自用许可（Personal Use License）**

- ✅ 可以：自己编译、自己安装、自己修改、学习参考
- ❌ 不可以：商业使用、二次分发、上架应用商店、作为付费产品的组成部分
- 代码按「现状」提供，不提供任何担保

---

<p align="center">
  <sub>墨语 · 会 AI 的输入法 · 为 Windows 用户而做</sub>
</p>
