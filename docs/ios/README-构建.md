# 构建 · 从源码到 iPhone 真机（工程骨架篇）

> 这份文档由 **ios-skeleton（工程骨架负责人）** 维护，讲的是**工程本身怎么打开、怎么编译、怎么装到手机上**。
> 如果你只是想「尽快用上这个输入法」，先看更短的 [04 · 安装与续签指南](../04-安装与续签指南.md)（那条路线不需要 Mac，全程 Windows）。
> 本文是它的**技术补充**：工程结构、必须手填的设置、pbxproj 打不开时的兜底方案、以及踩坑时的定位方法。

---

## ⚠️ 先读这一条（最容易翻车的地方）

> **任何对 `ios/Shared/`、`ios/AIKeyboard/`、`ios/AIKeyboardExtension/` 里 `.swift` 文件的增删改，之后都必须重跑一次生成器：**
>
> ```bash
> python scripts/gen_xcodeproj.py
> ```
>
> 原因：`ios/AIKeyboard.xcodeproj/project.pbxproj` 是**脚本按磁盘上的真实文件树生成的**，不是手写的。
> 新加的 `.swift` 如果没重跑脚本，就**不会**被编进 target —— 表现是 Xcode 报 `cannot find 'XXX' in scope`，
> 或者 CI 编译失败但本地看不出任何问题。
>
> 一条命令跑完全部闸门（生成 + 结构校验 + QA 三件套）：
>
> ```bash
> # Windows 开发机
> powershell -NoProfile -ExecutionPolicy Bypass -File scripts/finalize.ps1
> # macOS / CI
> bash scripts/finalize.sh
> ```
>
> **不要手改 `project.pbxproj`**：下次重跑脚本会把它整个覆盖掉，你的改动会凭空消失。
> 要改工程结构，就改 [scripts/gen_xcodeproj.py](../../scripts/gen_xcodeproj.py) 或 [ios/Config/](../../ios/Config/) 下的 xcconfig。

---

## 0. 先看清楚你手上有什么

| 事实 | 说明 | 对你的影响 |
|---|---|---|
| 本项目**只有 Windows 电脑** | 工作目录 `C:\你的路径\输入法`，无 Mac、无 Xcode、无 swift 命令 | **iOS 只能编译于 macOS**，这是苹果的硬限制，绕不过去（不是项目选择，见 [docs/01 §6](../01-产品需求与方案.md)） |
| 没有 Apple Developer Program | 只有免费 Apple ID | 签名 **7 天** 过期；**没有 App Group / iCloud / Push**；Bundle ID 必须全局唯一 |
| 零第三方依赖 | 不用 CocoaPods / SPM / Carthage | 所以**没有** `.xcworkspace`，用 `-project + -scheme` 即可 |
| 工程是**脚本生成**的 | `scripts/gen_xcodeproj.py` 用 Python 标准库按磁盘真实文件生成 `project.pbxproj` | 新增 `.swift` 后要**重跑脚本**，不要手改 pbxproj |

你有两条路可以编译，选一条：

- **路线 A（推荐，不需要 Mac）**：GitHub Actions 云端 macOS 编译 → 下载未签名 IPA → Windows 上用 Sideloadly 用自己的 Apple ID 重签 → 装到 iPhone。
  完整操作见 [04 · 安装与续签指南](../04-安装与续签指南.md)；本文第 6 章只讲**工程侧**的注意事项。
- **路线 B（有 Mac 时最省事）**：Xcode 直接打开工程 → Run 到真机。见本文第 2–4 章。

---

## 1. 工程结构（你应该看到什么）

```text
ios/
├── AIKeyboard.xcodeproj/            ← Xcode 工程（**由脚本生成，不要手改**）
│   ├── project.pbxproj              ← 由 scripts/gen_xcodeproj.py 生成，约 800 行
│   ├── project.xcworkspace/         ← Xcode 自动创建的空 workspace（不是 CocoaPods 那个）
│   └── xcshareddata/xcschemes/
│       ├── AIKeyboard.xcscheme      ← ★ CI 里 `-scheme AIKeyboard` 靠它（必须 shared）
│       └── AIKeyboardExtension.xcscheme
├── project.yml                      ← 人类可读的工程声明（参考文件，不参与构建）
├── Config/                          ← xcconfig / Info.plist / entitlements（**改这里，不改进 pbxproj**）
├── Resources/Assets.xcassets/       ← AppIcon + AccentColor（脚本生成）
├── Shared/                          ← 两个 target 共用的 Swift 源码 + dict/ 词库
├── AIKeyboard/                      ← 宿主 App（SwiftUI）
└── AIKeyboardExtension/             ← 键盘扩展（KeyboardViewController）
```

两个 target：

| target | 产品 | Bundle ID 占位 | 源码来源 | 资源 |
|---|---|---|---|---|
| `AIKeyboard` | `AIKeyboard.app`（`com.apple.product-type.application`） | `com.example.moyu` | `ios/AIKeyboard/**` + `ios/Shared/**` | `Resources/Assets.xcassets`（AppIcon）+ `Shared/dict`（词库，folder reference） |
| `AIKeyboardExtension` | `AIKeyboardExtension.appex`（`com.apple.product-type.app-extension`） | `com.example.moyu.keyboard` | `ios/AIKeyboardExtension/**` + `ios/Shared/**` | `Shared/dict`（folder reference） |

App 通过 **"Embed Foundation Extensions"** Copy Files 阶段（`dstSubfolderSpec = 13`、`dstPath = ""`）把 `.appex` 嵌进 App 包内的 `PlugIns` 目录，并依赖（`PBXTargetDependency`）Extension target。**这个阶段丢了，键盘装上去也不会出现在「设置 › 通用 › 键盘」里** —— 这是最常见的翻车点。

两个 target 在 `TargetAttributes` 里都带了 `CreatedOnToolsVersion = 15.0` 与 **`ProvisioningStyle = Automatic`**（Xcode 新建工程的模板也会写这两行）。后者与 xcconfig 里的 `CODE_SIGN_STYLE = Automatic` 呼应；少了它，首次打开工程时签名面板可能反复弹「需要选择 Provisioning Style」。

### 1.1 这个工程是怎么被验证的（为什么你可以指望它打得开）

pbxproj 是**脚本生成**的，所以"能不能被 Xcode 接受"必须先自己想办法证明。本工程用 **4 道互相独立**的检查：

| # | 检查 | 实现 | 能证明什么 | 不能证明什么 |
|---|---|---|---|---|
| 1 | 生成器自检 | `python scripts/gen_xcodeproj.py --check` | 重跑输出与磁盘完全一致（**幂等**）；目录扫描没有漏文件 | 生成的格式对不对 |
| 2 | 结构校验器 | `python scripts/validate_project.py`（86 项） | 括号平衡、UUID 无悬挂/无孤儿、build file→fileRef 存在、两个 target 的 phases 齐全、Embed 阶段 `dstSubfolderSpec=13`、plist/entitlements 路径存在、源码双向成员关系、scheme 有效、Resources 成员正确 | 用的是**自研解析器**，若作者对格式的理解本身就错，可能"自洽地错" |
| 3 | QA 独立校验 | `python scripts/qa/project_check.py`（qa-docs 写，**与 1/2 不同人不同代码**） | 从另一套正则/解析逻辑复核 target、UUID、Embed、源码归属、Build Settings 关键字 | 同上，仍是"读文本"而非真编译器 |
| 4 | **第三方库交叉验证** | `mod-pbxproj`（Python 生态常用 pbxproj 解析/编辑库，非本项目代码；仅一次性离线验证，**不是构建依赖**） | 完整加载 → 读出 2 个 target / 332 个对象 / Sources 90+63 / Resources 2+1 / CopyFiles `dstSubfolderSpec=13` / 所有 `PBXBuildFile.fileRef` 均存在 → **round-trip 重新渲染成功（94 KB）**，且 0 处报错 | 仍不等于 Xcode 的解析器 |

> 第 4 道的意义：第 2、3 道都是"自己人写的校验器"，最怕**生成器和校验器共享同一个错误理解**。第三方独立实现能干净地解析并往返渲染，说明这份 pbxproj 的 OpenStep 语法、对象图和 UUID 引用关系**在第三方实现下同样成立**，大幅降低"Xcode 打不开"的概率 —— 但**唯一能给出"能打开、能编译"结论的，仍然只有 macOS 上的 Xcode/`xcodebuild`**（见第 6 章的 CI）。

---

## 2. 路线 B：在 Mac 上用 Xcode 打开（从零到真机）

### 2.1 准备

- macOS 13+（Ventura 或更新），Xcode 14 / 15 / 16 任一版本（工程 `objectVersion = 56`、`compatibilityVersion = Xcode 14.0`，向下兼容到 Xcode 14）
- 一根能传数据的 Lightning / USB-C 线
- Apple ID（免费即可）

### 2.2 打开工程

```bash
# 把整个仓库目录拷到 Mac（U 盘 / 网盘 / AirDrop / git clone 都行）
cd <仓库路径>/ios
open AIKeyboard.xcodeproj        # 或双击 ios/AIKeyboard.xcodeproj
```

打开后左侧导航树应当看到：

```text
AIKeyboard
├── AIKeyboard            ← 宿主 App：App / Main / Settings / Playground / Guide / Components / Support
├── Config                ← xcconfig / plist / entitlements
├── Resources             ← Assets.xcassets
├── Shared                ← IMECore / Models / Networking / Prompts / Storage / Theme / dict
└── Products
    ├── AIKeyboard.app
    └── AIKeyboardExtension.appex
```

> 运行时 bundle 结构（**重新构建**出的 IPA 解包后）：`Payload/AIKeyboard.app/dict/{base_dict.tsv,phrases.tsv,dict_meta.json}` 与 `Payload/AIKeyboard.app/PlugIns/AIKeyboardExtension.appex/dict/{...}`。
> **词库目录在 bundle 根下必须叫 `dict`，不能叫 `Resources`**（见 §5.2 的说明：iOS 27 installd 会拒绝根目录下的 `Resources`）。
> ⚠️ 如果你手上的 `dist/AIKeyboard-unsigned.ipa` 是 2025-10 之前构建的，它还是旧布局（bundle 根下有 `Payload/AIKeyboard.app/Resources/dict/`，装到 iOS 27 上会失败），必须重新跑发布流程/CI 得到新包。

顶部的 scheme 选择器应当有 **AIKeyboard** 与 **AIKeyboardExtension** 两项（这两个 scheme 是 shared 的，已提交在 `xcshareddata/xcschemes/` 里，所以谁打开都能看到）。

> ✅ 自检：`Product › Scheme › Manage Schemes…` 里两个 scheme 的 **Shared** 列应该是勾上的。

### 2.3 【必做】改 Bundle ID（三处，缺一不可）

免费 Apple ID 的 Bundle ID **只要和别人撞了就签不下来**，所以 `com.example.moyu` 这种占位一定要改。

| # | 文件 | 改什么 | 示例 |
|---|---|---|---|
| 1 | `ios/Config/App.xcconfig` | `PRODUCT_BUNDLE_IDENTIFIER = com.example.moyu` | `PRODUCT_BUNDLE_IDENTIFIER = com.zhangsan.moyu` |
| 2 | `ios/Config/Extension.xcconfig` | `PRODUCT_BUNDLE_IDENTIFIER = com.example.moyu.keyboard` | `PRODUCT_BUNDLE_IDENTIFIER = com.zhangsan.moyu.keyboard` |
| 3 | `ios/Config/Base.xcconfig` | `DEVELOPMENT_TEAM =`（留空） | 留空即可，在 Xcode 面板里选 Team（见 2.4） |

**扩展的 Bundle ID 必须是 App 的 Bundle ID + `.keyboard`**。不满足会报：
`Embedded binary's bundle identifier is not prefixed with the parent app's bundle identifier.`

改完 **`Product › Clean Build Folder`（⇧⌘K）** 再编译。

### 2.4 【必做】选 Team

1. 左侧点项目（蓝色图标）→ 中间选 **TARGETS › AIKeyboard** → **Signing & Capabilities**
2. `Team` 下拉选你的 **Personal Team**（免费 Apple ID 登录后会有）
3. `Bundle Identifier` 这里应当显示你刚在 xcconfig 里改的值；`Signing Certificate` 显示 `Apple Development`
4. 切到 **TARGETS › AIKeyboardExtension**，**同样选一遍 Team**（两个 target 必须同一个 Team）

> 注意：Xcode 会把你选的 Team 写进 `project.pbxproj`（`DEVELOPMENT_TEAM = XXXXXXXXXX;`）。
> 这是**正常现象**，但如果你之后又重跑了 `python scripts/gen_xcodeproj.py`，pbxproj 会被重新生成 → **Team 会被清掉，需要回来再选一次**。

### 2.5 连真机并 Run

1. iPhone 用数据线连 Mac，手机上点「信任此电脑」
2. Xcode 顶部设备选择器选你的 iPhone（不要选模拟器 —— **模拟器不支持第三方键盘**，键盘装不上也切不出来）
3. 点 ▶ Run（⌘R）
4. 首次会弹「无法验证开发者」之类的提示，见 2.6

> **不要用模拟器验证键盘。** 模拟器里第三方键盘行为与真机差异很大（能安装但不稳定/不出现），本项目只保证真机路径。

### 2.6 手机端信任开发者

设置 → 通用 → **VPN 与设备管理** → 在「开发者 App」下点你的 Apple ID → **信任 "Apple Development: 你的名字"** → 弹窗点「信任」。

（iOS 16/17 叫「VPN 与设备管理」，iOS 15 及更早叫「描述文件与设备管理」。）

### 2.7 启用键盘（关键，很多人卡在这）

1. 设置 → 通用 → **键盘** → 点 **键盘**（第二项，进入键盘列表）
2. **添加新键盘…** → 找到 **墨语**（在「第三方键盘」分组里，可能最底部）
3. 勾选 → 右上角 **完成**
4. **点一下「墨语」这一行**（不是勾选框，是文字）→ 进入详细设置
5. 打开 **允许完全访问** → 弹窗点 **允许**

> 🔴 **第 5 步是 AI 功能的生死线**：不开完全访问，键盘**不能联网**，所有 AI 按钮只会提示去设置里开启。
> 打字本身不受影响。技术上对应 `Extension-Info.plist` 里 `NSExtensionAttributes.RequestsOpenAccess = YES`。

切换键盘：打字时点地球键 🌐（长按可直接选墨语）。

### 2.8 编译报错？先看这几条

| 报错关键字 | 原因 | 解决 |
|---|---|---|
| `Signing for "AIKeyboard" requires a development team` | 没选 Team | 回 2.4，两个 target 都要选 |
| `No profiles for 'com.example.moyu' were found` / `Failed to register bundle identifier` | Bundle ID 被别人占用，或没改占位 | 回 2.3 换成你自己的唯一 ID |
| `Embedded binary's bundle identifier is not prefixed...` | 扩展 Bundle ID 不是 App Bundle ID + `.keyboard` | 回 2.3 改 `Extension.xcconfig` |
| `The project named "AIKeyboard" does not contain a scheme named "AIKeyboard"` | scheme 没共享 | 确认 `ios/AIKeyboard.xcodeproj/xcshareddata/xcschemes/AIKeyboard.xcscheme` 存在；否则重跑 `python scripts/gen_xcodeproj.py` |
| `No such file or directory: .../Config/App-Info.plist` | 文件没拷全 | 确认 `ios/Config/` 整个目录都在 |
| `Cannot find 'XXX' in scope`（Shared 里的类） | 新增了 `.swift` 但没重跑生成器 | `python scripts/gen_xcodeproj.py` 后重新打开工程 |
| `Undefined symbol` / 重复符号 | 同一文件被加了两次 | 重跑生成器（它会重建 Sources 阶段，不会重复） |
| 键盘在列表里找不到 | `.appex` 没被嵌入 | 检查 App target 的 Build Phases 里有没有 **Embed Foundation Extensions**（`dstSubfolderSpec = 13`） |

---

## 3. 构建配置在哪改（不要在 Xcode 面板里改）

所有构建设置都在 **xcconfig** 里，`project.pbxproj` 每次都由脚本重新生成，所以**在 Xcode Build Settings 面板里的修改会在下次生成时丢失**。

| 想改什么 | 改哪个文件 | 关键字段 |
|---|---|---|
| 最低系统版本 | `ios/Config/Base.xcconfig` | `IPHONEOS_DEPLOYMENT_TARGET = 16.0` |
| Swift 版本 | `ios/Config/Base.xcconfig` | `SWIFT_VERSION = 5.0` |
| 支持 iPhone/iPad | `ios/Config/Base.xcconfig` | `TARGETED_DEVICE_FAMILY = 1,2` |
| 签名方式 | `ios/Config/Base.xcconfig` | `CODE_SIGN_STYLE = Automatic` |
| 开发团队 | `ios/Config/Base.xcconfig` | `DEVELOPMENT_TEAM =`（留空，用户自己填） |
| App 的 Bundle ID / 名字 / Info.plist / 图标 | `ios/Config/App.xcconfig` | `PRODUCT_BUNDLE_IDENTIFIER` / `PRODUCT_NAME` / `INFOPLIST_FILE` / `ASSETCATALOG_COMPILER_APPICON_NAME` |
| 扩展的 Bundle ID / Info.plist / 只允许扩展 API / 不参与安装 | `ios/Config/Extension.xcconfig` | `PRODUCT_BUNDLE_IDENTIFIER` / `INFOPLIST_FILE` / `APPLICATION_EXTENSION_API_ONLY = YES` / `SKIP_INSTALL = YES` |

### 3.1 必须手填的 Build Settings 清单（兜底建工程时逐条核对）

如果用了第 5 章的兜底方案（在 Xcode 里新建工程、手拖文件），**下面这些设置必须手工补齐**，否则不是编不过就是键盘不出现。

**工程级（Project › Info › Configurations，两个 target 继承）**

| Build Setting | 值 | 为什么 |
|---|---|---|
| `IPHONEOS_DEPLOYMENT_TARGET` | `16.0` | 用了 iOS 16 API；太低编不过 |
| `SWIFT_VERSION` | `5.0` | 与源码语法一致 |
| `TARGETED_DEVICE_FAMILY` | `1,2` | iPhone + iPad |
| `CODE_SIGN_STYLE` | `Automatic` | 免费账号只能用自动签名 |
| `DEVELOPMENT_TEAM` | 你的 Team ID（或留空在面板选） | 没有它无法签名 |
| `ENABLE_BITCODE` | `NO` | iOS 已废弃 bitcode |
| `ALWAYS_SEARCH_USER_PATHS` | `NO` | 防止误捡系统头文件 |
| `SWIFT_OPTIMIZATION_LEVEL`（Debug） | `-Onone` | 调试断点/预览正常 |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS`（Debug） | `DEBUG` | `#if DEBUG` 生效 |

**AIKeyboard（App target）**

| Build Setting | 值 |
|---|---|
| `PRODUCT_NAME` | `AIKeyboard` |
| `PRODUCT_MODULE_NAME` | `AIKeyboard` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.example.moyu`（**改成你自己的**） |
| `INFOPLIST_FILE` | `ios/Config/App-Info.plist`（Xcode 面板里显示为相对工程根 ios/ 的短路径） |
| `GENERATE_INFOPLIST_FILE` | `NO`（Info.plist 是手写的，不要让 Xcode 再生成） |
| `CODE_SIGN_ENTITLEMENTS` | `ios/Config/AIKeyboard.entitlements`（相对 `ios/`） |
| `ASSETCATALOG_COMPILER_APPICON_NAME` | `AppIcon` |
| `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` | `AccentColor` |
| `APPLICATION_EXTENSION_API_ONLY` | `NO` |
| `SKIP_INSTALL` | `NO` |
| `LD_RUNPATH_SEARCH_PATHS` | `$(inherited) @executable_path/Frameworks` |

**AIKeyboardExtension（扩展 target）**

| Build Setting | 值 | 为什么 |
|---|---|---|
| `PRODUCT_NAME` | `AIKeyboardExtension` | 产物名 |
| `PRODUCT_MODULE_NAME` | `AIKeyboardExtension` | **`NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).KeyboardViewController` 依赖它** |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.example.moyu.keyboard`（= App ID + `.keyboard`） | 不匹配会嵌入失败 |
| `INFOPLIST_FILE` | `ios/Config/Extension-Info.plist`（相对 `ios/`） | 键盘注册声明在这 |
| `GENERATE_INFOPLIST_FILE` | `NO` | 同上 |
| `CODE_SIGN_ENTITLEMENTS` | `ios/Config/AIKeyboardExtension.entitlements`（相对 `ios/`） | 默认空 |
| `APPLICATION_EXTENSION_API_ONLY` | `YES` | 扩展必须；`UIApplication.shared` 之类的 API 会直接编译失败，这正是我们要的 |
| `SKIP_INSTALL` | `YES` | 扩展不能被单独安装，只能被 App 嵌入 |
| `LD_RUNPATH_SEARCH_PATHS` | `$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks` | 扩展运行时找框架的路径 |
| `ASSETCATALOG_COMPILER_APPICON_NAME` | （留空） | 扩展不需要 AppIcon |

**Build Phases（兜底建工程时最容易漏的）**

- App target 必须有 **Copy Files** 阶段，名称可为 `Embed Foundation Extensions`：
  - Destination = **Frameworks**（pbxproj 里是 `dstSubfolderSpec = 13`）
  - Subpath = **空**
  - 里面有一条 `AIKeyboardExtension.appex`，勾选 **Code Sign On Copy**
  - **不要**勾 "Remove Headers on Copy" 之外的额外选项（本项目只要求 `RemoveHeadersOnCopy` 这个属性）
- App target 的 **Target Dependencies** 里要有 `AIKeyboardExtension`

---

## 4. 改完源码后：重跑生成器（重要）

`project.pbxproj` 里的文件列表是**生成时**的快照。任何人新增/删除 `.swift`、改目录结构之后，都要重跑：

```bash
# 在仓库根目录执行（Windows / macOS 都行，只要装了 Python 3）
python scripts/gen_xcodeproj.py        # 重新扫描磁盘，重建工程
python scripts/validate_project.py     # 结构自检（花括号/UUID/阶段/路径/plist）
```

- 生成器是**幂等**的：UUID 由「文件相对路径 + target」的 MD5 派生，所以同样的文件树永远生成同样的 pbxproj，重跑不会抖动（第二次跑会显示「实际写入 0 个」）。
- 想只看会不会变、不写盘：`python scripts/gen_xcodeproj.py --check`（有差异退出码 1）。
- 想同时校验其他智能体的产物：`python scripts/qa/project_check.py`（QA 维护的独立校验器）。

### 4.1 一条命令跑完全部闸门（推荐）

不想记顺序就跑收尾脚本，它按 `gen → validate → qa/project_check → qa/static_check → qa/consistency_check` 依次执行，**任一失败立刻中止**并打印 `[失败] X 退出码 = N`：

```powershell
# Windows（PowerShell 5.1 或 7 都行；加 -ExecutionPolicy Bypass 免得被策略挡）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/finalize.ps1
```

```bash
# macOS / CI
bash scripts/finalize.sh
```

常用开关：`-Check`（第 1 步改成只检查不写盘，等价 `gen_xcodeproj.py --check`）、`-SkipGen`（跳过第 1 步）。完整跑一遍约十几秒。

### 4.2 并行开发期间：让生成器自己盯着

多人/多智能体同时往 `ios/Shared/`、`ios/AIKeyboard/`、`ios/AIKeyboardExtension/` 里写 `.swift` 时，最容易出现的现象是「代码明明写了，编译却说 `cannot find 'XXX' in scope`」—— 因为 `project.pbxproj` 还没重生成。

```bash
# 盯着上面三个目录 + gen_xcodeproj.py 本身，文件一变就自动 gen + validate
python scripts/watch_gen.py

# 只跑一次再退出（CI 里做一次自检也用这个）
python scripts/watch_gen.py --once

# 只报告变化、不真的生成
python scripts/watch_gen.py --dry-run --interval 5
```

默认 3 秒轮询一次，`--interval N` 可调（最小 1 秒）。它监视 `.swift`/`.plist`/`.xcconfig`/`.tsv`/`.json`/`.txt`。**注意：它是开发期便利工具，不是构建的一部分**；最终提交前请用 `finalize.ps1` 跑一遍完整闸门（watcher 只跑 gen + validate，不跑 QA 三件套）。另外别让它一直挂在后台跑 CI —— CI 里重新生成一次就够了。

> ⚠️ **并行开发期间特别提示**：本仓库由多个智能体/多人并行写不同的目录。
> 如果你发现 `ios/AIKeyboardExtension/` 下还没有 `.swift` 文件（或者新加的类没被编进去），
> **等其他模块落盘后重跑 `python scripts/gen_xcodeproj.py` 即可**，不需要改任何配置。
> 目录还没落盘时，`validate_project.py` 和生成器都会给 **WARNING**（不是错误）而不是崩溃，例如：
> `EXT-SOURCE-MISSING ios/AIKeyboardExtension/ 下还没有任何 .swift`、
> `SOURCES-EMPTY AIKeyboardExtension 的 Sources 阶段为空 → 该 target 无法编译`、
> `APP-RESOURCES-SHARED App 的 Resources 阶段没有 Shared/dict`（磁盘上该目录还不存在时才是 WARNING；
> 目录存在却没被工程引用则仍是 P0 错误）。
> 只有「目录确实存在、工程却没引用」才是真正的结构缺陷。

---

## 5. 兜底方案：pbxproj 打不开 / 结构坏了怎么办

> 手写/生成 pbxproj 总有翻车可能（尤其是跨 Xcode 版本改动之后）。
> **不要慌，也不要去手改 pbxproj**。用下面这条 30 分钟的兜底路线，从零用 Xcode 模板重建工程，然后把源码拖进去。

### 5.1 第一步：先在 Mac 上新建一个干净的工程

1. Xcode → **File › New › Project…**
2. 选 **iOS › App** → Next
3. 填写：
   - Product Name: `AIKeyboard`
   - Team: 你的 Personal Team
   - Organization Identifier: 你改好的前缀，例如 `com.zhangsan`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **None**
   - 勾掉 "Include Tests"
4. 保存到一个**空目录**（例如 `~/Desktop/rebuild/AIKeyboard`），不要直接覆盖仓库里的 `ios/`
5. 再新建扩展：**File › New › Target…** → **iOS › Custom Keyboard Extension** →
   - Product Name: `AIKeyboardExtension`
   - Language: Swift
   - 不要勾 "Include Notification Scene" 等任何附加项
   - 弹出 "Activate AIKeyboardExtension scheme?" 点 **Activate**

> ✅ 此时你在 `rebuild` 目录里得到了 AIKeyboard.xcodeproj，里面有 `AIKeyboard` + `AIKeyboardExtension` 两个 target，
> 并且 App target 已经**自动**带上了 `Embed Foundation Extensions` 阶段。

### 5.2 第二步：删掉模板文件，拖入仓库源码

在 Xcode 里删（**Move to Trash**，不要 Remove Reference）模板生成的：

- App 侧：`AIKeyboardApp.swift`、`ContentView.swift`（如果模板建了）
- 扩展侧：`KeyboardViewController.swift`、`Info.plist`（模板的）

然后把仓库里这三个文件夹**分别拖进** Xcode 导航树，注意弹窗选项：

| 拖入 | 拖到哪个 target | 弹窗选项 |
|---|---|---|
| `ios/AIKeyboard/`（整个文件夹） | 只勾 **AIKeyboard** | ✅ Copy items if needed **不勾**（引用原位置）；✅ Create groups |
| `ios/AIKeyboardExtension/`（整个文件夹） | 只勾 **AIKeyboardExtension** | 同上 |
| `ios/Shared/`（整个文件夹） | **两个都勾**（AIKeyboard + AIKeyboardExtension） | 同上 |

> 💡 `ios/Shared/` 里同时有 `.swift` 和 `dict/*.tsv`。
> 拖进去后，选中 `Shared/dict` 这个**文件夹**，在右侧 File Inspector 里把 **Type** 改成
> **Folder**（蓝色文件夹图标）→ 这样它会作为 folder reference 整个拷进两个 target 的 Bundle，
> `Bundle.main.url(forResource: "base_dict", withExtension: "tsv", subdirectory: "dict")` 才能找到词库。
>
> ⚠️ **词库文件夹必须叫 `dict`，绝对不能叫 `Resources`。** folder reference 会把文件夹名
> 原样复制到 bundle 根目录：叫 `dict` 就得到 bundle 根下的 `dict/`（正常）；叫 `Resources`
> 就会得到 bundle 根下的 `Resources/`，而 **iOS 27 的 installd / IXPlaceholder 会拒绝
> app bundle 根目录下存在名为 `Resources` 的目录**——真机实测即使该目录是空的也会让安装失败，
> 报 `IXErrorDomain Code=13 Missing bundle ID`，很多人会误判成签名或证书问题。

再拖入资源与配置文件：

| 拖入 | target | 说明 |
|---|---|---|
| `ios/Resources/Assets.xcassets` | AIKeyboard | 图标与品牌色 |
| `ios/Config/`（整个文件夹，不勾任何 target） | 无 | 只是为了让 Xcode 能引用里面的 plist |

### 5.3 第三步：配置 Build Settings

打开 **Project › Info › Configurations**，把 Debug/Release 的 xcconfig 指到仓库里的文件：

- 项目级两个配置 → `ios/Config/Base.xcconfig`
- `AIKeyboard` target 两个配置 → `ios/Config/App.xcconfig`
- `AIKeyboardExtension` target 两个配置 → `ios/Config/Extension.xcconfig`

（在 Xcode 里：选中 target → Info 标签 → 底部 Configurations → 展开 Debug/Release → 右侧下拉选 `Base`/`App`/`Extension`。
如果下拉里看不到这些名字，先执行 `Product › Clean Build Folder`，或直接用 3.1 的清单逐条手填。）

**然后按 3.1 的表格逐条核对一遍必须手填的 Build Settings** —— 这是兜底方案里唯一容易漏的环节。

### 5.4 第四步：验证兜底工程

1. `Product › Build`（⌘B）：应当编译通过，没有 "Cannot find in scope"
2. 选中 `AIKeyboard` scheme，`Product › Archive` 或直接 Run 到真机
3. build 完到 `DerivedData` 里确认路径 `.../Build/Products/Debug-iphoneos/AIKeyboard.app/PlugIns/AIKeyboardExtension.appex` 存在

```bash
# 一句命令验证 .appex 被嵌入了（在 Mac 终端跑）
find ~/Library/Developer/Xcode/DerivedData -name "AIKeyboardExtension.appex" -path "*PlugIns*"
```

4. 真机装好后按 2.6 / 2.7 信任开发者 + 添加键盘

---

## 6. 路线 A：没有 Mac 时怎么编译（Windows 用户路径）

**核心思路**：Mac 上的编译步骤交给 GitHub Actions 的 macOS runner 免费跑，产物是**未签名 IPA**；
签名和安装回到 Windows 上用 Sideloadly 完成（用你自己的免费 Apple ID，7 天续签一次）。

工程侧需要你知道的只有三件事（其余全在 [04 · 安装与续签指南](../04-安装与续签指南.md)）：

1. **workflow 文件是 `.github/workflows/build.yml`**（已在仓库里）。
   - 手动触发：GitHub 仓库页 → **Actions** 标签 → 左侧 **Build Unsigned IPA** → **Run workflow**
   - 或在 push 到 `main` 时自动触发（只监听 `ios/**` 与三个脚本的改动）
2. **它做的事**（跟本文第 2 章在 Mac 上做的是同一套）：
   ```bash
   xcodebuild -project ios/AIKeyboard.xcodeproj \
              -scheme AIKeyboard \
              -configuration Release \
              -sdk iphoneos \
              -derivedDataPath build/dd \
              -archivePath build/App.xcarchive \
              CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
              CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
              archive
   # → build/Payload/AIKeyboard.app → ditto 打包成 AIKeyboard-unsigned.ipa
   ```
   注意用的是 **`-project`** 不是 `-workspace`（本仓库没有 xcworkspace，零第三方依赖）。
   流水线里有**强校验**：IPA 里如果少了 `Payload/AIKeyboard.app/PlugIns/AIKeyboardExtension.appex`，构建会**故意失败**并打印原因 —— 防止你装上后键盘根本不出现。
3. **产物**：运行页底部 Artifacts → `AIKeyboard-unsigned-ipa`（zip，解压得到 `.ipa`，保留 7 天）。
   下载后按 [docs/04](../04-安装与续签指南.md) 第 4 章用 Sideloadly 签名安装。

> 📌 关于 `scripts/gen_xcodeproj.py`：CI 里会**先重跑一遍生成器**（`python3 scripts/gen_xcodeproj.py`），
> 再 `xcodebuild`。所以哪怕有人新加了 `.swift` 忘了重跑脚本，云端也会自动把文件纳入工程；
> 如果生成结果与仓库里的 pbxproj 有差异，日志里会打印 `git diff` 让你知道有人手改过 pbxproj。

---

## 7. 常见问题（工程侧）

**Q1：仓库里没有 .xcworkspace 工作区文件，是缺东西吗？**
不是。本项目零第三方依赖、没有 Pods，Xcode 打开 `.xcodeproj` 即可。CI 里也统一用 `-project`。
（`project.xcworkspace` 那是个目录，Xcode 自己维护的空壳，正常。）

**Q2：为什么 pbxproj 里没有我新加的文件？**
生成器在 Windows 上没重跑。执行 `python scripts/gen_xcodeproj.py`，然后 Xcode 里 **File › Close Project** 再重新打开（不是 reload，要关掉重开）。

**Q3：`validate_project.py` 报 WARNING 怎么办？**
看内容。骨架阶段最常见的是 `EXT-SOURCE-MISSING`（`ios/AIKeyboardExtension/` 还没落盘）——这是并行开发的正常状态，等其他模块写完重跑生成器即可。
如果是 `FILEREF-MISSING`（工程里列了磁盘上不存在的文件）→ 说明有文件被删/改名了，重跑生成器。

**Q4：我在 Xcode 面板里改了 Bundle ID/Team，重跑生成器后丢了？**
正常。pbxproj 是生成物，权威在 `ios/Config/` 目录下的 xcconfig 文件。改 xcconfig 才对（Team 除外：Team ID 只能面板选，重跑后可再选一次）。

**Q5：扩展内存 40–60MB 怎么控制？**
这是键盘扩展的硬限制（iOS 决定）。扩展侧只做 UI 和轻量逻辑，词库/网络/存储的活都在 Shared 的可复用代码里，注意不要在扩展启动路径上加载大文件。详见 [02 · 技术架构](../02-技术架构与接口契约.md)。

**Q6：能开 App Groups 吗？**
免费 Apple ID **不能**（不支持 App Group capability）。本工程的 entitlements 是**空 dict**，App ⇄ 键盘通过共享存储 + 命名 Pasteboard 同步。
如果以后买了付费账号想开：参考 `ios/Config/AIKeyboard.entitlements.appgroup.sample` 里的注释，把两边的 `.entitlements` 换成带 `com.apple.security.application-groups` 的版本即可。

**Q7：工程打不开 / Xcode 报 "The project 'AIKeyboard' is damaged and cannot be opened"？**
说明 pbxproj 结构坏了。**不要手改**，直接重跑 `python scripts/gen_xcodeproj.py`；如果你在 Mac 上又没有 Python（不太可能，macOS 自带 python3），就用第 5 章的兜底方案新建工程。

---

## 8. 快速命令卡

```bash
# ===== 仓库根目录执行 =====

# 重新生成 Xcode 工程（改了 .swift 之后必做；幂等）
python scripts/gen_xcodeproj.py

# 只看会不会变，不写盘
python scripts/gen_xcodeproj.py --check

# 结构校验（P0 错误会让工程打不开，退出码 1）
python scripts/validate_project.py
python scripts/validate_project.py -v      # 打印每个通过的检查项

# 生成 AppIcon + AccentColor（用 design/ 里的正式设计稿）
python scripts/make_appicon.py --from design/appicon/icon-1024.png --force

# 一条命令跑完 6 个闸门（gen → validate → project_check → static_check → consistency_check → pbxproj_plist_check）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/finalize.ps1

# 开发期自动重生成（文件一变就 gen + validate，Ctrl+C 退出）
python scripts/watch_gen.py

# QA 的独立校验（由 qa-docs 维护）
python scripts/qa/project_check.py
```

```bash
# ===== Mac 上 =====

# 打开工程
open ios/AIKeyboard.xcodeproj

# 命令行编译到真机（不需要开 Xcode）
xcodebuild -project ios/AIKeyboard.xcodeproj -scheme AIKeyboard -configuration Debug -destination 'generic/platform=iOS' build

# 只看工程里有哪些 target / scheme（排查"scheme 找不到"）
xcodebuild -list -project ios/AIKeyboard.xcodeproj

# 验证 .appex 有没有被嵌进 App
find ~/Library/Developer/Xcode/DerivedData -name "AIKeyboardExtension.appex" -path "*PlugIns*"
```

---

## 9. 相关文档

| 文档 | 内容 |
|---|---|
| [04 · 安装与续签指南](../04-安装与续签指南.md) | ★ Windows 全程：云编译 → Sideloadly → 启用键盘 → 7 天续签 → 16 条报错对照表 |
| [05 · 常见问题](../05-常见问题.md) | 28 个高频疑问（安全/耗电/迁移/费用…） |
| [02 · 技术架构与接口契约](../02-技术架构与接口契约.md) | 目录归属、编码规范、接口签名 |
| [01 · 产品需求与方案](../01-产品需求与方案.md) | 做什么、不做什么、硬约束 |
| [ios/Config/README.md](../../ios/Config/README.md) | xcconfig 逐字段说明、改 Bundle ID / Team 的正确姿势 |
| [ios/Config/扩展心跳契约.md](../../ios/Config/扩展心跳契约.md) | 扩展写 / App 读的两个心跳键（`moyu.ext.lastActiveAt`、`moyu.ext.lastNetworkOKAt`）及其无 App Group 限制 |
| [ios/project.yml](../../ios/project.yml) | 人类可读的工程声明（XcodeGen 参考，不参与构建） |

---

> **维护者**：ios-skeleton（工程骨架负责人）
> **已知限制**：本工程在 **Windows 上生成**，作者**无法在 Windows 上用 Xcode 验证**。
> 生成器与校验器都是双保险（`gen_xcodeproj.py` + `validate_project.py` + QA 的 `project_check.py`），
> 结构层面已覆盖 UUID 完整性、build phases、plist、entitlements、scheme、源码归属等 85+ 项检查，
> 并用第三方库 `mod-pbxproj` 做过独立解析 + round-trip 交叉验证（见 §1.1）；
> 但**"Xcode 真的能打开、真的能编译"这一步只能在 macOS 上完成**。
> 如果打开或编译有问题，请用第 5 章的兜底方案，并把报错贴回来。
>
> **关于 `import UIKit` 与 `APPLICATION_EXTENSION_API_ONLY = YES`**：`ios/Shared/Theme/Theme.swift` 与
> `ios/Shared/Storage/PasteboardBridge.swift` 确实 `import UIKit`，这是**允许的** —— 该设置禁止的是
> `UIApplication.shared` / `openURL` / `beginBackgroundTask` 这类**扩展不可用的 API 调用**，不是禁止 import UIKit 本身。
> 已核对 `ios/Shared/**` 中 `UIApplication`、`openURL` 的非注释使用 **= 0 处**，扩展 target 不会因此编译失败。
> 若未来有人往 Shared 里加这类调用，CI 的 `xcodebuild` 会在扩展 target 上报 `APPLICATION_EXTENSION_API_ONLY` 错误。
