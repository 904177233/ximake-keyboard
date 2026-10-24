# ios/Shared/Theme — 设计令牌映射表

> 模块职责：把 `design/tokens.json` 的七组令牌（color / typography / spacing / radius /
> sizing / motion / shadow）翻译成 Swift 常量，供宿主 App 与键盘扩展统一引用。
> 使用方：`ios/AIKeyboard/**`、`ios/AIKeyboardExtension/**`。
> 依赖：`SwiftUI`（`Color` / `Font` / `Animation`）+ `UIKit`（仅 `UIColor` 动态色）。
> 令牌版本：**tokens `1.0`**（`design/tokens.json` 的 `meta.version`），`Theme.swift` 文件头注释 `// tokens: 1.0`。

**唯一入口**：`public enum Theme`。UI 代码只允许引用 `Theme.*`，禁止页面内写裸色值与魔法数字。
颜色全部是 `UIColor { traits in … }` 动态色，在 SwiftUI 里用 `Color(uiColor:)` 包装后**自动跟随深色模式**，
不需要手写 `@Environment(\.colorScheme)` 分支。

---

## 1. 颜色映射（36 对 · 契约 15 个 + 扩展 21 个）

> `design/tokens.json` 的 `color.light` / `color.dark` 各有 36 个键，上面的 Swift 常量与之一一对应。
> 「契约」= `docs/02` §4.5 明确列出的公开常量名，**UI 两个 agent 只用这些**；「扩展」= 本版为了
> 精细还原设计稿补充的常量，纯新增，不影响契约。

### 契约 15 个（`docs/02` §4.5）

| tokens 键 | Swift 常量 | 浅色 / 深色 | 用途 |
| --- | --- | --- | --- |
| `bg.keyboard` | `Theme.keyboardBackground` | `#D1D3D9` / `#2C2C2E` | 键盘整体背景（字母区之下） |
| `bg.key` | `Theme.keyBackground` | `#FFFFFF` / `#636366` | 字母键帽底色 |
| `bg.key.pressed` | `Theme.keyBackgroundPressed` | `#E5E5E5` / `#7A7A7E` | 键帽按下态 |
| `bg.key.function` | `Theme.keyFunctionBackground` | `#ADB3BC` / `#48484A` | 功能键（Shift / Delete / 切键盘）底色 |
| `bg.surface` | `Theme.surface` | `#FFFFFF` / `#1C1C1E` | 主 App 卡片 / Sheet 面 |
| `bg.surfaceElevated` | `Theme.surfaceElevated` | `#F2F2F7` / `#2C2C2E` | 分组列表 / 内嵌卡片 |
| `text.primary` | `Theme.textPrimary` | `#000000` / `#FFFFFF` | 主文字 |
| `text.secondary` | `Theme.textSecondary` | `#3C3C4399` / `#EBEBF599` | 次要文字（说明、占位说明） |
| `accent` | `Theme.accent` | `#0A84FF` / `#0A84FF` | 主色（发送、选中、链接、AI 强调） |
| `accent.soft` | `Theme.accentSoft` | `#0A84FF1A` / `#0A84FF33` | 主色淡底（选中候选、chip 底） |
| `separator` | `Theme.separator` | `#3C3C434D` / `#54545899` | 分隔线 |
| `success` | `Theme.success` | `#34C759` / `#30D158` | 成功（已保存 / 连通） |
| `warning` | `Theme.warning` | `#FF9F0A` / `#FFD60A` | 警告（未配置 Key） |
| `danger` | `Theme.danger` | `#FF3B30` / `#FF453A` | 危险（删除、错误） |
| `candidate.bar` | `Theme.candidateBar` | `#FFFFFF` / `#3A3A3C` | 候选栏背景 |

### 扩展 21 个

| tokens 键 | Swift 常量 | 浅色 / 深色 | 用途 |
| --- | --- | --- | --- |
| `bg.key.function.pressed` | `Theme.keyFunctionBackgroundPressed` | `#9AA0A9` / `#565658` | 功能键按下态 |
| `bg.surfaceGrouped` | `Theme.surfaceGrouped` | `#F2F2F7` / `#000000` | 分组列表页底色 |
| `bg.glassTint` | `Theme.glassTint` | `#FFFFFF33` / `#FFFFFF1A` | 玻璃材质叠加色 |
| `text.tertiary` | `Theme.textTertiary` | `#3C3C434D` / `#EBEBF54D` | 三级文字 / 禁用态 |
| `text.placeholder` | `Theme.textPlaceholder` | `#3C3C4399` / `#EBEBF54D` | 输入框占位符 |
| `text.onAccent` | `Theme.textOnAccent` | `#FFFFFF` / `#FFFFFF` | 主色之上的文字 |
| `accent.pressed` | `Theme.accentPressed` | `#0070E0` / `#409CFF` | 主色按下态 |
| `separator.opaque` | `Theme.separatorOpaque` | `#C6C6C8` / `#38383A` | 不透明分隔线（列表） |
| `success.soft` | `Theme.successSoft` | `#34C7591A` / `#30D15826` | 成功淡底 chip |
| `warning.soft` | `Theme.warningSoft` | `#FF9F0A1A` / `#FFD60A26` | 警告淡底 chip |
| `danger.soft` | `Theme.dangerSoft` | `#FF3B301A` / `#FF453A26` | 危险淡底 chip |
| `candidate.selected` | `Theme.candidateSelected` | `#0A84FF1A` / `#0A84FF40` | 候选词选中态 |
| `candidate.separator` | `Theme.candidateSeparator` | `#3C3C4326` / `#54545866` | 候选栏内分隔线 |
| `chip.bg` | `Theme.chipBackground` | `#FFFFFFCC` / `#FFFFFF1F` | 胶囊 chip 底 |
| `chip.bg.pressed` | `Theme.chipBackgroundPressed` | `#FFFFFF99` / `#FFFFFF14` | 胶囊 chip 按下态 |
| `chip.border` | `Theme.chipBorder` | `#FFFFFF66` / `#FFFFFF2E` | 胶囊 chip 描边 |
| `chip.text` | `Theme.chipText` | `#1C1C1E` / `#FFFFFF` | 胶囊 chip 文字 |
| `shadow.key` | `Theme.keyShadow` | `#00000026` / `#00000066` | 键帽投影色 |
| `keyboard.topShadow` | `Theme.keyboardTopShadow` | `#00000014` / `#00000040` | 键盘顶部上投影色 |
| `overlay.scrim` | `Theme.overlayScrim` | `#00000066` / `#00000099` | 蒙层遮罩 |
| `ai.glow` | `Theme.aiGlow` | `#0A84FF33` / `#0A84FF4D` | AI 按钮光晕 |

### 扩展键核对（design-lead 最新 `tokens.json` 的 10 个新增键）

下表是 `design-lead` 在 `color` 组补充的 10 个扩展键，逐个确认**已在 `Theme.swift` 中实现、
且 README 上表中已登记**（值取 `color.light` / `color.dark`，与 tokens 完全一致）：

| tokens 键 | Swift 常量 | 浅色 / 深色 | 用途 |
| --- | --- | --- | --- |
| `bg.key.function.pressed` | `Theme.keyFunctionBackgroundPressed` | `#9AA0A9` / `#565658` | 功能键按下态（与 `bg.key.pressed` 成对） |
| `bg.surfaceGrouped` | `Theme.surfaceGrouped` | `#F2F2F7` / `#000000` | 分组列表页整页底色（浅色同 `bg.surfaceElevated`，深色更暗） |
| `text.onAccent` | `Theme.textOnAccent` | `#FFFFFF` / `#FFFFFF` | 主色块之上的文字（发送键、主按钮） |
| `separator.opaque` | `Theme.separatorOpaque` | `#C6C6C8` / `#38383A` | 不透明分隔线（列表分隔，不用半透明叠加） |
| `candidate.separator` | `Theme.candidateSeparator` | `#3C3C4326` / `#54545866` | 候选栏内候选词之间的细竖线 |
| `chip.bg.pressed` | `Theme.chipBackgroundPressed` | `#FFFFFF99` / `#FFFFFF14` | 玻璃胶囊 chip 按下态 |
| `chip.border` | `Theme.chipBorder` | `#FFFFFF66` / `#FFFFFF2E` | 玻璃胶囊 chip 描边（0.5pt） |
| `keyboard.topShadow` | `Theme.keyboardTopShadow` | `#00000014` / `#00000040` | 键盘顶部上投影色（配 `Theme.Shadow.keyboardTop`） |
| `overlay.scrim` | `Theme.overlayScrim` | `#00000066` / `#00000099` | Sheet / 弹层的蒙层遮罩 |
| `ai.glow` | `Theme.aiGlow` | `#0A84FF33` / `#0A84FF4D` | AI 工具条 / AI 按钮的外发光 |

**覆盖度自检**：`color.light` / `color.dark` 各 36 键 = 契约 15 + 扩展 21，
`Theme.swift` 中 36 个 `adaptive(...)` 常量与之一一对应，**无缺键、无色值偏差**；
`scripts/qa/consistency_check.py` 的 `colors_checked=72`（36 对 × 2）与 `numbers_checked=93` 保持 100%。

### 深浅色自适应实现

```swift
private static func adaptive(_ light: String, _ dark: String) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
    })
}
```

`UIColor(dynamicProvider:)` 在 SwiftUI 里被 `Color(uiColor:)` 包装后会随 trait 变化自动刷新，
因此**同一个常量在深色模式下就是深色值**，无需重启、无需分支。iOS 16 完全可用。

`Color(hex:)` / `UIColor(hex:)` 支持 6 位（`RRGGBB`，alpha = 1）与 8 位（`RRGGBBAA`），
可带 `#` 前缀，大小写不敏感；非法输入返回**透明色**（不崩溃、不抛错）。

---

## 2. 字体映射（typography 12 组）

| tokens 键 | size / weight | Swift 常量 | 用途 |
| --- | --- | --- | --- |
| `candidate` | 17 / regular | `Theme.fontCandidate` | 候选词 |
| `key` | 22 / regular | `Theme.fontKey` | 键帽字母 |
| `body` | 15 / regular | `Theme.fontBody` | 正文 |
| `caption` | 12 / regular | `Theme.fontCaption` | 说明文字 |
| `title` | 20 / semibold | `Theme.fontTitle` | 卡片标题（契约 5 个之一） |
| `headline` | 17 / semibold | `Theme.fontHeadline` | 小节标题 / 按钮强调 |
| `chip` | 13 / medium | `Theme.fontChip` | 胶囊 chip |
| `result` | 16 / regular | `Theme.fontResult` | 结果卡片正文 |
| `largeTitle` | 34 / bold | `Theme.fontLargeTitle` | 大标题（首页） |
| `footnote` | 13 / regular | `Theme.fontFootnote` | 脚注 |
| `button` | 17 / semibold | `Theme.fontButton` | 主按钮 |
| `monoDigit` | 16 / medium | `Theme.fontMonoDigit` | 等宽数字（Key 掩码、token 统计） |

契约 5 个字体是 `fontCandidate` / `fontKey` / `fontBody` / `fontCaption` / `fontTitle`。
全部用 `Font.system(size:weight:design:)` 构造（跟随 Dynamic Type 的系统字号体系之外的固定尺寸，
键盘 UI 必须固定尺寸，否则键盘高度会随字号变化而错位）。

---

## 3. 间距（spacing 10 键）

| tokens 键 | 值 | Swift 常量 | 说明 |
| --- | --- | --- | --- |
| `xs` | 2 | `Theme.Spacing.xs` | 行内最小间隙 |
| `sm` | 4 | `Theme.Spacing.sm` | 紧凑间隙 |
| `md` | 8 | `Theme.Spacing.md` | 默认间隙 |
| `lg` | 12 | `Theme.Spacing.lg` | 卡片内边距 |
| `xl` | 16 | `Theme.Spacing.xl` | 页面左右边距 / 区块间 |
| `xxl` | 24 | `Theme.Spacing.xxl` | 大区块间 |
| `xxxl` | 32 | `Theme.Spacing.xxxl` | 页面级留白 |
| `screenMargin` | 16 | `Theme.Spacing.screenMargin` | 页面左右安全边距 |
| `sectionGap` | 28 | `Theme.Spacing.sectionGap` | 设置页分组之间 |
| `rowMinHeight` | 44 | `Theme.Spacing.rowMinHeight` | 列表行最小高度（= 最小点按目标） |

契约 5 个：`xs` / `sm` / `md` / `lg` / `xl`（UI 两个 agent 只用这 5 个）。

---

## 4. 圆角（radius 8 键）

| tokens 键 | 值 | Swift 常量 | 用途 |
| --- | --- | --- | --- |
| `key` | 8 | `Theme.Radius.key` | 键帽 / 设置行 |
| `card` | 16 | `Theme.Radius.card` | 卡片 |
| `capsule` | 999 | `Theme.Radius.capsule` | 胶囊（等价 `Capsule()`） |
| `sheet` | 24 | `Theme.Radius.sheet` | Sheet 顶部 |
| `chip` | 14 | `Theme.Radius.chip` | 玻璃胶囊片 |
| `control` | 10 | `Theme.Radius.control` | 按钮 / 输入框 |
| `thumbnail` | 12 | `Theme.Radius.thumbnail` | 缩略图 |
| `small` | 6 | `Theme.Radius.small` | 小标签 |

契约 4 个：`key` / `card` / `capsule` / `sheet`。配合 `.continuous` 曲线使用（`RoundedRectangle(cornerRadius:style:.continuous)`）。

---

## 5. 尺寸（sizing 38 键）

### 契约 9 个（`docs/02` §4.5 / §5）

| tokens 键 | 值 | Swift 常量 | 用途 |
| --- | --- | --- | --- |
| `keyboardHeightPortrait` | 258 | `Theme.Sizing.keyboardHeightPortrait` | 竖屏键盘总高 |
| `keyboardHeightLandscape` | 200 | `Theme.Sizing.keyboardHeightLandscape` | 横屏键盘总高 |
| `candidateBarHeight` | 44 | `Theme.Sizing.candidateBarHeight` | 候选栏高度 |
| `aiBarHeight` | 40 | `Theme.Sizing.aiBarHeight` | AI 工具条高度 |
| `keyHeight` | 42 | `Theme.Sizing.keyHeight` | 单行键帽高度 |
| `keyGap` | 6 | `Theme.Sizing.keyGap` | 键帽纵向/横向间距 |
| `keyHorizontalPadding` | 3 | `Theme.Sizing.keyHorizontalPadding` | 键盘左右内边距 |
| `aiPanelExtraHeight` | 168 | `Theme.Sizing.aiPanelExtraHeight` | AI 面板展开后额外增加的高度 |
| `resultExtraHeight` | 180 | `Theme.Sizing.resultExtraHeight` | 结果卡片展开后额外增加的高度 |

### 扩展 29 个

键盘几何：`keyboardRowCount`(4, Int) / `letterRowHeight`(39) / `letterRowPitchLandscape`(34.5) /
`letterKeyWidth`(33) / `functionKeyWidth`(42) / `returnKeyWidth`(88) / `numberKeyWidth`(108) /
`spaceBarWidth`(194)；
AI 区：`aiChipHeight`(30) / `aiChipGap`(8) / `aiChipMinWidth`(56) / `aiBarInset`(8) / `aiBarFadeWidth`(24) /
`aiPanelInputHeight`(44) / `aiPanelToneRowHeight`(44)；
候选栏：`candidateItemMinWidth`(48) / `candidateItemGap`(20) / `pageDotSize`(6) / `pageDotGap`(5)；
结果卡片：`resultCardMinHeight`(120) / `resultCardHeight`(180) / `resultActionHeight`(36)；
通用：`minTapTarget`(44) / `statusBarHeight`(47) / `homeIndicatorHeight`(34) / `tabBarHeight`(49) /
`largeTitleHeight`(52) / `navBarHeight`(44) / `appIconSize`(1024)。

---

## 6. 动效（motion）

| tokens 键 | 值 | Swift 常量 | 用途 |
| --- | --- | --- | --- |
| `fast` | 0.15 | `Theme.Motion.fast` | 轻量状态切换（`withAnimation(.easeOut(duration: …))`） |
| `normal` | 0.25 | `Theme.Motion.normal` | 常规过渡 |
| `springDuration` | 0.35 | `Theme.Motion.springDuration` | 弹簧 response |
| `springDamping` | 0.82 | `Theme.Motion.springDamping` | 弹簧阻尼 |
| `keyPress` | 0.08 | `Theme.Motion.keyPress` | 按键按下高亮 |
| `expandDuration` | 0.35 | `Theme.Motion.expandDuration` | AI 面板展开 |
| `collapseDuration` | 0.28 | `Theme.Motion.collapseDuration` | AI 面板收起 |
| `streamCursorBlink` | 0.9 | `Theme.Motion.streamCursorBlink` | 流式输出光标闪烁周期 |
| `toastDuration` | 2.0 | `Theme.Motion.toastDuration` | Toast 停留时长 |
| `reducedMotionScale` | 0 | `Theme.Motion.reducedMotionScale` | 开启「减弱动态效果」时的缩放系数 |

`design/04-AI对话与智能联想规范.md` §6（方案 A）新增的 3 个 motion 键**全部复用已有数值**，
不新增独立常量（避免同一数值两处定义、日后改一处漏一处），映射关系如下：

| tokens 键 | 值 | 复用哪个 Swift 常量 | 用途 |
| --- | --- | --- | --- |
| `suggestDebounce` | 0.35 | `Theme.Motion.springDuration`（同值 0.35） | 智能联想输入防抖 |
| `knobPress` | 0.08 | `Theme.Motion.keyPress` | 对话旋钮按下缩放时长 |
| `knobActiveFade` | 0.15 | `Theme.Motion.fast` | 旋钮激活态淡入淡出 |

> 键盘侧 `ios/AIKeyboardExtension/Theme/KMLayout.swift` 已就地把它们包成语义名
> （`KMLayout.suggestDebounce` / `knobPress` / `knobActiveFade`）并标注 `// TOKEN: motion.xxx`；
> 共享层不再复制一份，`consistency_check.py` 的数值覆盖因此仍为 100%。

契约 3 个：`fast`(Double) / `normal`(Double) / `spring`(Animation)。

```swift
public static let spring: Animation = .spring(response: springDuration, dampingFraction: springDamping)
```

**`spring` 用 iOS 16 可用的 `Animation.spring(response:dampingFraction:)`**，
不使用 iOS 17+ 的 `.spring(duration:bounce:)`；另外提供 `fastAnimation`(`.easeOut`) /
`normalAnimation`(`.easeInOut`)，省掉 UI 每次现拼 `Animation`。

---

## 7. 阴影（shadow 5 组）

```swift
public struct Shadow: Equatable, Sendable {
    public let y: CGFloat
    public let blur: CGFloat
    public let opacity: Double
    public init(y: CGFloat, blur: CGFloat, opacity: Double)
    public static let key: Shadow          // y 1,  blur 0,  opacity 0.18
    public static let card: Shadow         // y 8,  blur 24, opacity 0.12
    public static let chip: Shadow         // y 1,  blur 4,  opacity 0.08
    public static let glass: Shadow        // y 2,  blur 16, opacity 0.10
    public static let keyboardTop: Shadow  // y -1, blur 0,  opacity 0.08
}
```

用法：

```swift
.shadow(
    color: Theme.keyShadow,          // 颜色常量化，避免写 #00000026
    radius: Theme.Shadow.key.blur,
    x: 0,
    y: Theme.Shadow.key.y
)
```

> SwiftUI 的 `.shadow(color:radius:x:y:)` **没有 opacity 参数**，`opacity` 已经烘焙进 `shadow.key`
> 这类颜色令牌的 alpha 里；`Shadow.opacity` 仅供需要使用 `CGContext` / `UIView.layer.shadowOpacity`
> 的 UIKit 场景参考（两者数值一致）。

---

## 8. 材质（material · 本版扩展，可选实现）

| tokens 键 | SwiftUI | blurRadius | iOS 16 回退 |
| --- | --- | --- | --- |
| `material.bar` | `.ultraThinMaterial` | 20 | 不透明叠加色 `bg.surface` α0.94 |
| `material.card` | `.thinMaterial` | 24 | 不透明叠加色 α1.0 |
| `material.sheet` | `.regularMaterial` | 30 | 不透明叠加色 α1.0 |

`Theme.MaterialToken` 暴露：`barBlurRadius`(20) / `cardBlurRadius`(24) / `sheetBlurRadius`(30) /
`strokeWidth`(0.5) / `barFallbackAlpha`(0.94) / `cardFallbackAlpha`(1.0)。
材质组是 tokens 里的**可选扩展组**（`meta.note` 已注明），不实现也不影响契约。

---

## 9. iOS 16 兼容性清单

| 用了 | 说明 |
| --- | --- |
| `Color(uiColor:)` + `UIColor { traits in }` | iOS 13+，深色自动跟随 |
| `Animation.spring(response:dampingFraction:)` | iOS 13+ |
| `Font.system(size:weight:design:)` | iOS 13+ |
| `.ultraThinMaterial` / `.thinMaterial` / `.regularMaterial` | iOS 15+ |

**明确未使用**：`Color.mix`（iOS 18）、`MeshGradient`（iOS 18）、`.symbolEffect`（iOS 17）、
`.spring(duration:bounce:)`（iOS 17）、`@Observable`（iOS 17）。

---

## 10. 交叉校验

`ios/Shared/selfcheck.py` 的 `check_theme_tokens` 会读 `design/tokens.json`，
把 36 个 `adaptive("light","dark")` 常量与 `color.light` / `color.dark` **逐键比对**，
任何色值不一致直接 FAIL。`scripts/qa/consistency_check.py` 也会做 tokens → Theme.swift 覆盖度检查
（`colors_checked=72`，即 36 对 × 2），当前两边都是 **P0=0 / P1=0**。

改色流程：**先改 `design/tokens.json`（design-lead 负责）→ 再同步 `Theme.swift` → 跑两个脚本**。
`Theme.swift` 顶部的 `// tokens: 1.0` 必须与 `meta.version` 一致。
