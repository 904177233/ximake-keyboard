# ios/Config —— 构建设置与清单文件

> 本目录由 **ios-skeleton** 独占维护。所有构建设置都写在 xcconfig 里，
> `project.pbxproj` 不写死这些值，因此重跑 `scripts/gen_xcodeproj.py` 不会丢配置。

## 文件清单

| 文件 | 作用 | 谁用 |
|---|---|---|
| `Base.xcconfig` | 平台、版本、Swift、警告、签名策略等**公共**设置 | App + Extension 共同 `#include` |
| `App.xcconfig` | 宿主 App：`PRODUCT_NAME`/Bundle ID/Info.plist/entitlements/AppIcon | `AIKeyboard` target |
| `Extension.xcconfig` | 键盘扩展：Bundle ID/Info.plist/entitlements/`APPLICATION_EXTENSION_API_ONLY`/`SKIP_INSTALL` | `AIKeyboardExtension` target |
| `App-Info.plist` | 宿主 App 的 Info.plist | `AIKeyboard` target |
| `Extension-Info.plist` | 扩展 Info.plist（`NSExtension` 键盘服务声明） | `AIKeyboardExtension` target |
| `AIKeyboard.entitlements` | App 的 entitlements（**默认空**，免费签名） | `AIKeyboard` target |
| `AIKeyboardExtension.entitlements` | 扩展的 entitlements（**默认空**） | `AIKeyboardExtension` target |
| `AIKeyboard.entitlements.appgroup.sample` | App Groups **样例**，仅付费账号使用，见文件内注释 | 手动启用，不参与构建 |
| `扩展心跳契约.md` | 跨 target 运行时契约：扩展写 / App 读的两个 `UserDefaults` 心跳键 | 扩展 + App 两侧代码，不参与构建 |

## 你需要改的三处（免费 Apple ID）

1. **`App.xcconfig`** → `PRODUCT_BUNDLE_IDENTIFIER = com.example.moyu`
   改成你自己唯一的反向域名，例如 `com.zhangsan.moyu`。
2. **`Extension.xcconfig`** → `PRODUCT_BUNDLE_IDENTIFIER = com.example.moyu.keyboard`
   必须等于 App 的 Bundle ID + `.keyboard`，**否则 Xcode 报嵌入二进制 bundle id 不匹配**。
3. **`Base.xcconfig`** → `DEVELOPMENT_TEAM =`
   留空即可；在 Xcode 里打开工程后在 *Signing & Capabilities* 面板选自己的 Personal Team，
   Xcode 会把 Team ID 写进 pbxproj（优先级高于 xcconfig，属正常现象）。
   如果重跑 `gen_xcodeproj.py` 覆盖了 pbxproj，需要**回到面板再选一次 Team**。

## 重要约定

- **不要在 Xcode 的 Build Settings 图形界面里改** `SWIFT_VERSION`、`IPHONEOS_DEPLOYMENT_TARGET`
  这类值：会被写进 pbxproj，下次重跑生成器就丢了。改 xcconfig。
- xcconfig 里 `//` 是注释起点，所以**不能写 URL**（`https://` 会被截断）。
  需要 URL 用 `https:/$()/` 的写法，或干脆写进 Swing 代码/plist。
- 本工程**不使用 App Groups**（免费账号不支持）。App ⇄ 键盘的配置同步走
  `SharedStore` 的三级策略 + `PasteboardBridge` 命名剪贴板。
- **扩展心跳**（`moyu.ext.lastActiveAt` / `moyu.ext.lastNetworkOKAt`）的读写契约见
  `扩展心跳契约.md`。注意：没有 App Group 时 `UserDefaults.standard` 按进程隔离，
  扩展写的心跳宿主 App 读不到，App 诊断页会诚实显示「没有检测到使用记录」——
  这是平台限制，不是 bug，付费启用 App Groups 后自动打通。
- 部署目标 `16.0`：iOS 17+ 的 API 一律 `if #available` 判断或不用。

## 相关脚本

```bash
# 重新生成 Xcode 工程（幂等，可反复跑）
python scripts/gen_xcodeproj.py

# 结构校验（花括号平衡 / UUID 引用完整 / build phases 齐全 / 路径存在）
python scripts/validate_project.py

# 生成 AppIcon + AccentColor
python scripts/make_appicon.py
python scripts/make_appicon.py --from design/appicon/icon-1024.png
```
