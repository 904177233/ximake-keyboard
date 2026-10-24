//
//  MainTabView.swift
//  墨语 · 宿主 App
//
//  模块职责：主界面三个 Tab（键盘 / AI 试验场 / 设置）及各自导航栈。
//  依赖：SwiftUI、AppState、KeyboardHomeView、PlaygroundView、SettingsView。
//  使用方：RootView。
//

import SwiftUI

/// 主 Tab 容器。
struct MainTabView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            NavigationStack {
                KeyboardHomeView()
            }
            .tabItem {
                Label(MainTab.keyboard.title, systemImage: MainTab.keyboard.systemImage)
            }
            .tag(MainTab.keyboard)

            NavigationStack {
                PlaygroundView()
            }
            .tabItem {
                Label(MainTab.playground.title, systemImage: MainTab.playground.systemImage)
            }
            .tag(MainTab.playground)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(MainTab.settings.title, systemImage: MainTab.settings.systemImage)
            }
            .tag(MainTab.settings)
        }
        .tint(Theme.accent)
    }
}

#if DEBUG
struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
            .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
