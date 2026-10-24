//
//  RootView.swift
//  墨语 · 宿主 App
//
//  模块职责：根路由。首次启动 → 引导页；之后 → 主 TabView。
//  依赖：SwiftUI、AppState、OnboardingView、MainTabView。
//  使用方：AIKeyboardApp。
//

import SwiftUI

/// 根视图。
struct RootView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.hasCompletedOnboarding {
                MainTabView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.spring, value: appState.hasCompletedOnboarding)
        .background(AppColor.pageBackground.ignoresSafeArea())
    }
}

#if DEBUG
struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
