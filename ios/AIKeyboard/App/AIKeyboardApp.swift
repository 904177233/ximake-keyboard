//
//  AIKeyboardApp.swift
//  墨语 · 宿主 App
//
//  模块职责：App 入口。构造并注入 `AppState`，决定首选配色方案，挂载根视图。
//  依赖：SwiftUI、AppState。
//  使用方：系统（@main）。
//

import SwiftUI

/// 墨语 App 入口。
@main
struct AIKeyboardApp: App {

    /// 宿主 App 状态中枢（整个 App 唯一一份）。
    @StateObject private var appState = AppState()

    /// App 入口初始化。
    ///
    /// 在这里启动 MetricKit 订阅（而不是 `.onAppear`）有两个原因：
    /// ①MetricKit 要求尽早注册，越早越不容易漏掉系统投递的指标包；
    /// ②`.onAppear` 在场景重建时可能被多次触发，而 `init` 只在进程内走一次
    /// （`MetricKitReporter.start()` 自身也做了幂等保护，双保险）。
    init() {
        MetricKitReporter.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(appState.appearanceMode.colorScheme)
                .tint(Theme.accent)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .toastOverlay($appState.toast)
                .onAppear {
                    // 每次冷启动刷新一次派生状态（词库 / 扩展心跳 / Keychain）。
                    appState.refreshDerivedState()
                    if appState.isKeychainAvailable == false {
                        appState.showToast(
                            ToastMessage(
                                kind: .warning,
                                text: "钥匙串当前不可用",
                                detail: "API Key 无法保存，请稍后再试。"
                            )
                        )
                    }
                }
        }
    }
}

#if DEBUG
struct AIKeyboardApp_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
