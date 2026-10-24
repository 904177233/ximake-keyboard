# iOS 第三方键盘扩展能力边界与官方限制（技术约束清单）

> 适用：墨语 iOS AI 输入法 · 目标 iOS 16+ · 实机 iOS 27.0 (24A437) · 免费 Apple ID 侧载 · 无 App Group
> 结论均标注依据；「社区共识」类结论无官方文档，工程上按保守值取值。

---

### 1. 硬限制（做不了 / 做了会被拒）

- **不开完全访问 = 无网络、无共享容器、无剪贴板。** `RequestsOpenAccess=false`（Info.plist 默认）时官方逐条列明：除键盘自身沙盒容器外无文件系统访问、对宿主共享容器**只读**、无网络、无麦克风扬声器、不能参与 iCloud/Game Center/IAP。依据：https://developer.apple.com/tutorials/data/documentation/uikit/configuring-open-access-for-a-custom-keyboard.json
- **键盘内不能拉起任何 App（除「设置」）。** App Review 4.4.1 明文 "Launch other apps besides Settings"；且扩展里 `UIApplication.shared` 直接不可用，`NSExtensionContext.openURL` 只有 Today widget 能用。依据：https://developer.apple.com/app-store/review/guidelines/ + ExtensibilityPG/ExtensionOverview
- **`insertText(_:)` 只能插纯文本。** 它是 `UIKeyInput` 协议方法，参数是 `String`，无 NSAttributedString / 图片 / 自定义属性通道。贴图唯一路径是写 `UIPasteboard`（需完全访问 + 用户手动粘贴）。依据：UITextDocumentProxy / UIKeyInput 文档
- **`secureTextEntry` 与 `UIKeyboardTypePhonePad`/`NamePhonePad` 输入框强制换回系统键盘**，系统临时替换，无法绕过。依据：ExtensibilityPG/CustomKeyboard
- **不能在键盘上边缘之上绘制任何东西**（按键放大镜、内联自动更正气泡、候选浮层越界都算）；也不能选择文本、不能访问宿主的剪切/复制/粘贴菜单。依据：同上
- **无法枚举已启用键盘、也无法指定切到某个键盘**，只能 `advanceToNextInputMode()`；`needsInputModeSwitchKey` 为 true 时必须提供「下一输入法」键，否则审核不过（4.4.1 明文要求）。
- **麦克风：iOS 26 起大概率可用，但必须先真机验证。** 现行文档把 "No access to microphone and speaker" 放在 **`RequestsOpenAccess=false`** 的限制清单里；同一篇 open access 文档的开发者责任段又写 "don't store received **keystroke or voice data**..."（把语音与击键并列）。加上五家上架输入法的 App Store 描述都有键盘内语音手势（百度「长按空格即说即发」、讯飞「长按技能坞」、搜狗、微信、Gboard）与 `hkgood/OSGKeyboard`（minOS 26.0）扩展 Info.plist 的 `NSMicrophoneUsageDescription`，可判定 **iOS 26+ 大概率可做**。2014 存档文档 "have no access to the device microphone" 属 iOS 8 时代，已被打破。**前提**：开完全访问（我们 `RequestsOpenAccess` 已是 true）+ 补两个 Usage 字符串 + **30 分钟真机验证**。详见 `docs/08` §5.1。依据：configuring-open-access-for-a-custom-keyboard + CustomKeyboard.html + itunes.apple.com/lookup
- **宿主 App 可一键禁用所有第三方键盘**（`application(_:shouldAllowExtensionPointIdentifier:)` 返回 false），银行/医疗类 App 普遍这么做——这类 App 里墨语根本唤不出来。
- **必须无网络也能用。** 4.4.1 要求 "Remain functional without full network access and without requiring full access"；曾有人因「无网不能用」被以 25.5 拒。另：不得在键盘内放广告（2.5.18），不得内置 Apple emoji（5.2.5），不得把按键改成非输入行为（如长按 return 开相机）。
- **不能常驻后台。** 扩展生命周期由系统管，宿主 App 退后台仅约 180 秒即被挂起——"让宿主 App 当代算后端"的方案不成立。

### 2. 软限制（能做但要注意）

| 限制 | 具体数字/表现 | 应对手段 |
|---|---|---|
| **内存上限** | 官方只说「显著低于前台 App」从不给数字；社区实测区间 **30–66MB**（40MB 最常见，66MB 出现在 WKWebView 场景）。超限被 jetsam 杀，日志 `Terminated due to Memory error` | 按 **30MB** 做预算；不引入 WKWebView / 大图缓存；模型与词典用 mmap 或按需分片；`deinit` 断点 + Instruments 查闭包循环引用 |
| **冷启动预算** | 官方唯一硬数字：`aiming for well under one second. An extension that launches too slowly is terminated by the system.`（ExtensionCreation.html） | `viewDidLoad` 只搭骨架，词典/AI 客户端全部懒加载；首帧不读大 JSON |
| **按键响应** | 无官方值；社区实践要求 **< 50ms** 出字符，> 100ms 明显掉帧 | 按键回调里只做 `insertText` + 本地状态更新；候选/AI 一律异步，且用 `documentIdentifier` 丢弃过期回调 |
| **上文长度** | `documentContextBeforeInput` 官方**未声明上限**；社区实测约 **200 字符**，且常在句号/换行处被截断（iOS 8 起如此，2025 年仍有报告） | 只取尾部 N 字符做 prompt；需要更长上下文用「循环 `adjustTextPosition(byCharacterOffset:)` + 拼接」的 hack——会疯狂移动光标，不建议上生产 |
| **选中文本** | `selectedText`(iOS 11+) 实测只返回选中区**前后的句子**，拿不到完整选区 | 不要依赖 `selectedText` 做「选中即润色」；改为让用户走剪贴板或宿主 App |
| **网络** | 合法：扩展可 `initiate uploads or downloads using an NSURLSession`。但**不是** background session；iOS 26 SDK 起 URLSession 默认最低 TLS 从 1.0 升到 **1.2**（`tlsMinimumSupportedProtocolVersion` 可回退） | SSE 可行（`URLSession.bytes(for:)` 逐行解析），但**超时必须短**：`timeoutIntervalForRequest` 建议 20–30s，**不要**用 120s 级 resource timeout——扩展活不到那时候。建议 `URLSessionConfiguration.ephemeral` + `waitsForConnectivity = false` |
| **剪贴板** | iOS 16+ 主动读 `UIPasteboard.general.string` **必弹**「允许粘贴？」；无完全访问时 `UIPasteboard` 完全不工作，甚至报 `PBErrorDomain Code=7 "Cannot connect to pasteboard server"` | 用 `hasStrings`/`hasImages` 等类型检测属性预检（官方明说不触发通知）；真要免弹窗粘贴用 `UIPasteControl`（iOS 16+，需用户点按钮） |
| **共享数据** | 没有 App Group 时 `UserDefaults(suiteName:)` 不可用，`UserDefaults.standard` 在扩展里是**扩展独立域**，宿主读不到 | 命名剪贴板 `UIPasteboard(name:)` + magic 前缀 + 校验和是唯一可行通道，但官方要求**同 Team ID**，免费签名跨 Team 不保证；且同样受完全访问与弹窗限制 |
| **高度** | 宽度恒等于屏宽（不能改）；高度用主 view 的 height 约束改，iOS 8 起随时可改 | 见下方「真机坑」；动画用 `UIViewPropertyAnimator`，`Reduce Motion` 时禁用动画 |
| **生命周期** | `viewDidDisappear` **不保证调用**（Notes 里按 Home 就不走）；`viewWillDisappear` 也可能被跳过 | 清理逻辑不要只挂在 `viewDidDisappear`；用 `deactivate()` + 定时兜底 |
| **输入框自身** | 键盘里放 `UITextField` 会触发 `-[UIKeyboardInputManagerClient handleError:forRequest:]` 连接失效 | 键盘内绝不放原生输入框，用自绘/SwiftUI 无焦点控件 |

### 3. 可用但常被忽略的能力

- **`setMarkedText(_:selectedRange:)` 做内联补全预览**：range 只覆盖字符串一部分时，未选中部分会自动**加背景色**——可在输入框里直接展示「Anth → **ony**」式灰底补全，不用自建浮层（官方文档明确举例）。`unmarkText()` 清除标记但保留文本。
- **读 `UITextInputTraits`**：`UIInputViewController` 本身遵循该协议，可读到 `returnKeyType`、`autocapitalizationType`、`keyboardType`、`smartQuotesType`、`smartDashesType`——据此把「发送/搜索/换行」键画对，是很强的体验分。
- **`documentIdentifier`（UUID，iOS 11+）**：判断是否换了输入框，用于丢弃上一个输入框的异步 AI 结果，避免串字。
- **`UILexicon` / `requestSupplementaryLexicon(completion:)`**：白嫖系统「文本替换」快捷短语 + 通用词库，等于免费的用户自定义词表同步通道（无需完全访问）。
- **`primaryLanguage`**：运行中动态切换键盘语言，不必重建扩展。
- **`hasDictationKey`**：键盘自带听写入口时置 true，可让系统不再显示它自带的听写按钮。
- **`handleInputModeList(from:with:)`**：实现长按地球键的键盘选择菜单（配合 `advanceToNextInputMode()`）。
- **`dismissKeyboard()`**：主动收起键盘，做「AI 结果全屏展示」时必备。
- **`playInputClick()`**：按键音（需完全访问）。
- **`UIInputViewController.hasFullAccess`（iOS 11+）**：完全访问的唯一权威判断，必须在 `viewWillAppear` 与 `viewDidAppear` 各刷一次（用户在设置里开关后返回）。
- **Foundation Models（iOS 26.0+，`SystemLanguageModel` / `LanguageModelSession`）**：端侧文本生成，但**依赖设备与地区支持 Apple Intelligence**，且官方未承诺扩展进程可用——可作增强路径，不能作唯一路径。

### 4. 对我们项目的直接影响

**已做对的：**
- `ios/Config/Extension-Info.plist:39-68` 的 `NSExtensionPointIdentifier=com.apple.keyboard-service`、`IsASCIICapable=true`、`PrimaryLanguage=zh-Hans`、`RequestsOpenAccess=true` 全部正确。
- `KeyboardViewController.swift:71-73` **不覆写 `inputView`** 的判断正确——覆写会导致同一份视图被重复挂载。
- `KeyboardViewController.swift:242-302` 的 `syncHeightConstraintOnly` + `UIViewPropertyAnimator` 高度方案正确；而且你们已经踩到并修掉了「`viewWillLayoutSubviews` 里调 `layoutIfNeeded()` → `applyHeight → layoutBelowIfNeeded → viewWillLayoutSubviews` 递归 → `EXC_BAD_ACCESS / Thread stack size exceeded`」这个栈溢出崩溃，这条经验值得写进团队规范。
- `KeyboardViewModel+Input.swift:84-87` 的 `setMarkedText` 把 `selectedRange` 放在末尾，符合官方用法。
- `HTTPTransport.swift:16-25` 用 `ephemeral` + 禁缓存 + `waitsForConnectivity=false`，符合内存敏感场景。

**有风险的：**
1. **`KMFullAccessProbe` 用「能否读剪贴板」反推完全访问**（`KeyboardViewModel.swift:299`、`KeyboardViewModel+Access.swift:20-24`）。这与 `hasFullAccess` 不是同一语义，且 iOS 16+ 读 general pasteboard 会弹「允许粘贴？」——用户会莫名看到权限框。**建议直接删除该探测，只用 `hasFullAccess`**（`KMSupport.swift:19-27` 的注释其实已经写明了正确答案）。
2. **`SharedStore.swift` 的三级降级在无 App Group 时是假的**：`UserDefaults.standard` 在扩展里是扩展自己的域，心跳键 `moyu.ext.lastActiveAt` / `moyu.ext.lastNetworkOKAt` 宿主 App 根本读不到，诊断页会永远是空的。要么明确标注「无 App Group 时诊断不可用」，要么统一走 `PasteboardBridge`。
3. **`HTTPTransport.swift` 的 `timeoutIntervalForResource = max(..., 120)`** 远超键盘扩展存活窗口，应压到 30s 量级并允许取消。
4. **`PasteboardBridge.export()` 同时写 general pasteboard**，会污染用户剪贴板（用户复制的内容被冲掉），且读回时若回退到 general 会触发弹窗。建议只保留命名剪贴板 + magic 校验。
5. **`onDismissKeyboard` 调 `advanceToNextInputMode()`**（`KeyboardViewController.swift` bindModel 处）语义错误——「收起键盘」应该是 `dismissKeyboard()`，现在等于强制换输入法，用户会以为键盘抽风。
6. ~~**`docs/08` 的麦克风结论与 Apple 现行文档矛盾**~~ → **已闭环（2026-10-25，两轮订正）**：`docs/08` 初版依据某个开源项目的 Info.plist 直接下定论（证据太薄）；第一次订正时依据「无完全访问」清单里的 "No access to microphone and speaker" 推翻成「平台根本不给」；第二轮补齐三条独立证据后改回「**iOS 26+ 大概率可做，需 30 分钟真机验证**」。三条证据：①五家上架输入法的 App Store 描述都有键盘内语音手势（百度「长按空格即说即发」、讯飞「长按技能坞」、搜狗、微信、Gboard）；②`hkgood/OSGKeyboard`（minOS 26.0）的**扩展** Info.plist 声明了 `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`；③Apple open access 文档的开发者责任段写 "don't store received keystroke or **voice** data..."。那句话位于 **`RequestsOpenAccess=false`** 的限制清单里，不是全局禁令。详见 `docs/08` §5.1。**教训：单一来源（无论 plist 还是文档字符串）都不足以定论 —— 还要看它在哪一份清单里、以及现网产品实际怎么做的。**

**还没用上的：**
- `setMarkedText` 的**部分选区高亮**能力（现在只用来做 composing，没做内联补全预览）。
- `UITextInputTraits`（`returnKeyType` 等）完全没读，导致回车键在搜索框里仍是「换行」。
- `documentIdentifier` 没用，异步 AI 结果可能串到新输入框。
- `UILexicon` / `requestSupplementaryLexicon` 没用，白白丢掉系统文本替换词表。
- `UIPasteControl` 没用，任何粘贴动作都在弹权限框。

### 5. 信息来源

- https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html
- https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html
- https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html
- https://developer.apple.com/tutorials/data/documentation/uikit/configuring-open-access-for-a-custom-keyboard.json
- https://developer.apple.com/tutorials/data/documentation/uikit/handling-text-interactions-in-custom-keyboards.json
- https://developer.apple.com/tutorials/data/documentation/uikit/configuring-a-custom-keyboard-interface.json
- https://developer.apple.com/documentation/uikit/uiinputviewcontroller
- https://developer.apple.com/documentation/uikit/uitextdocumentproxy
- https://developer.apple.com/documentation/uikit/uipasteboard
- https://developer.apple.com/documentation/uikit/uipastecontrol
- https://developer.apple.com/app-store/review/guidelines/ （§4.4.1 / §2.5.18 / §5.2.5）
- https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes
- https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes
- https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel
- https://stackoverflow.com/questions/44275990/memory-limit-for-keyboard-extension
- https://stackoverflow.com/questions/33892770/ （50MB+ 被杀）
- https://stackoverflow.com/questions/71367775/ （66MB 上限）
- https://stackoverflow.com/questions/79608243/ （documentContextBeforeInput 约 200 字符）
- https://stackoverflow.com/questions/25773041/ （句号截断）
- https://stackoverflow.com/questions/79903594/ （selectedText 不可靠）
- https://stackoverflow.com/questions/26094913/ （无 App Group 无法共享）
- https://stackoverflow.com/questions/79796548/ （无完全访问的沙盒行为）
- https://stackoverflow.com/questions/39411701/ （关闭完全访问时 UIPasteboard 不工作）
- https://stackoverflow.com/questions/42599944/ （PBErrorDomain Code=7）
- https://stackoverflow.com/questions/29773505/ （viewDidDisappear 不保证调用）
- https://stackoverflow.com/questions/52572320/ （动态改高度）
