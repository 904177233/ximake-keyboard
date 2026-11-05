//
//  MoyuApp.swift
//  墨语 App · 入口
//
//  三页：开始（装好键盘）、AI（配服务）、键盘（外观和打字习惯）。
//

import SwiftUI

@main
struct MoyuApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootTabs()
                .environmentObject(model)
        }
    }
}

/// 键盘跳过来要录音。
struct VoiceRequest: Identifiable {
    let id = UUID()
}

/// 根页签。
@MainActor
struct RootTabs: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var voiceRequest: VoiceRequest?

    private var palette: MoyuPalette {
        MoyuPalette(theme: model.prefs.theme, dark: colorScheme == .dark)
    }

    var body: some View {
        TabView {
            StartView()
                .tabItem { Label("开始", systemImage: "house") }
            AIServicesView()
                .tabItem { Label("AI", systemImage: "sparkle") }
            KeyboardPrefsView()
                .tabItem { Label("键盘", systemImage: "keyboard") }
        }
        .tint(palette.accentText.color)
        .environment(\.palette, palette)
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.reload()
            }
        }
        .onOpenURL { url in
            if url.scheme == "moyu", url.host == "voice" {
                voiceRequest = VoiceRequest()
            }
        }
        .sheet(item: $voiceRequest) { _ in
            NavigationStack {
                VoiceSessionView(autoStart: true) { voiceRequest = nil }
            }
            .environmentObject(model)
            .environment(\.palette, palette)
        }
    }
}
