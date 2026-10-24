//
//  DiagnosticsChecklist.swift
//  墨语 · 宿主 App
//
//  模块职责：诊断页的检查逻辑 —— 组装 9 个自检项、测试服务商连通性、
//            检测公网、一键重测。作为 `DiagnosticsView` 的扩展拆出，
//            让视图文件保持在 docs/02 §3.7 的 600 行以内。
//  依赖：SwiftUI（@State 访问）、AppState、SharedBridge（ExtensionTelemetry /
//        ConnectivityProbe / ConfigExporter）、Shared（SharedStore / ConfigSnapshot）。
//  使用方：DiagnosticsView。
//

import SwiftUI

extension DiagnosticsView {

    // MARK: - 检查逻辑

    /// 重建全部检查项（同步部分）。
    /// 说明：9 项固定顺序，与 `docs/00` 的诊断规范一致。
    func rebuildChecks() {
        var items: [CheckItem] = []

        // 1. 键盘扩展
        let heartbeat = ExtensionTelemetry.lastActiveAt()
        let extensionState: CheckState
        let extensionDetail: String
        if let heartbeat {
            if Date().timeIntervalSince(heartbeat) <= ExtensionTelemetry.freshness {
                extensionState = .ok
                extensionDetail = "最近一次使用：\(ExtensionTelemetry.relativeDescription(heartbeat))。"
            } else {
                extensionState = .warning
                extensionDetail = "24 小时内没有检测到键盘被使用（最近一次：\(ExtensionTelemetry.relativeDescription(heartbeat))）。可能没添加，或只是没切过去。"
            }
        } else if appState.isExtensionInstalled {
            extensionState = .warning
            extensionDetail = "App 里能看到键盘扩展，但还没有检测到使用记录。请到「设置 › 通用 › 键盘 › 键盘」确认已添加墨语。"
        } else {
            extensionState = .failure
            extensionDetail = "没有在 App 包内找到键盘扩展（\(AppInfo.extensionBundleName)）。请确认安装的是完整包。"
        }
        items.append(
            CheckItem(
                id: "extension",
                title: "键盘扩展",
                state: extensionState,
                detail: extensionDetail,
                actionTitle: "如何确认",
                action: {
                    appState.showToast(
                        ToastMessage(
                            kind: .info,
                            text: "设置 › 通用 › 键盘 › 键盘",
                            detail: AppInfo.keyboardSettingsPath
                        )
                    )
                }
            )
        )

        // 2. 完全访问
        let networkOK = ExtensionTelemetry.lastNetworkOKAt()
        let accessState: CheckState
        let accessDetail: String
        if let networkOK, Date().timeIntervalSince(networkOK) <= ExtensionTelemetry.freshness {
            accessState = .ok
            accessDetail = "键盘最近联网成功：\(ExtensionTelemetry.relativeDescription(networkOK))。完全访问应该已开启。"
        } else {
            accessState = .warning
            accessDetail = "还没有检测到键盘联网记录。AI 需要完全访问权限，请到「\(AppInfo.openAccessPath)」开启。"
        }
        items.append(
            CheckItem(
                id: "fullAccess",
                title: "完全访问权限",
                state: accessState,
                detail: accessDetail,
                actionTitle: "复制设置路径",
                action: {
                    UIPasteboard.general.string = AppInfo.openAccessPath
                    appState.showToast(ToastMessage(kind: .success, text: "路径已复制"))
                }
            )
        )

        // 3. AI 服务配置
        let chatCount = appState.chatProviders.count
        let imageCount = appState.imageProviders.count
        let configState: CheckState = chatCount > 0 ? .ok : .failure
        let configDetail: String
        if chatCount == 0 {
            configDetail = "还没有配置 AI 服务商，键盘里的 AI 用不了。"
        } else {
            let defaultName = appState.defaultChatProvider?.name ?? "未指定"
            configDetail = "对话服务商 \(chatCount) 个（默认：\(defaultName)），生图服务商 \(imageCount) 个。"
        }
        items.append(
            CheckItem(
                id: "providers",
                title: "AI 服务配置",
                state: configState,
                detail: configDetail,
                actionTitle: "去配置",
                action: { appState.selectedTab = .settings }
            )
        )

        // 4. API 连通性（结果来自按钮触发）
        items.append(
            CheckItem(
                id: "connectivity",
                title: "API 连通性",
                state: providerTestState,
                detail: providerTestDetail,
                actionTitle: isTestingProvider ? nil : "测试",
                action: isTestingProvider ? nil : { testProvider() }
            )
        )

        // 5. 钥匙串
        let keychainState: CheckState = appState.isKeychainAvailable ? .ok : .failure
        let keychainDetail = appState.isKeychainAvailable
            ? "钥匙串可读写，API 密钥能安全保存。"
            : "钥匙串不可用，API 密钥无法保存。请重启设备后再试。"
        items.append(
            CheckItem(
                id: "keychain",
                title: "钥匙串",
                state: keychainState,
                detail: keychainDetail,
                actionTitle: nil,
                action: nil
            )
        )

        // 6. 本地词库
        if let info = appState.dictionaryInfo {
            items.append(
                CheckItem(
                    id: "dictionary",
                    title: "本地词库",
                    state: .ok,
                    detail: "词库 v\(info.version) · \(info.formattedWordCount) 词条，全部在本机。",
                    actionTitle: nil,
                    action: nil
                )
            )
        } else {
            items.append(
                CheckItem(
                    id: "dictionary",
                    title: "本地词库",
                    state: .warning,
                    detail: "没有读到内置词库，拼音输入可能不可用。",
                    actionTitle: nil,
                    action: nil
                )
            )
        }

        // 7. 存储模式
        let appGroup = ConfigExporter.isAppGroupAvailable
        items.append(
            CheckItem(
                id: "storage",
                title: "存储模式",
                state: appGroup ? .ok : .warning,
                detail: SharedStore.shared.storageStatusDescription
                    + (appGroup ? "" : "。可以用「同步到键盘」把配置搬过去。"),
                actionTitle: nil,
                action: nil
            )
        )

        // 8. 配置快照
        let snapshot = appState.snapshot
        let jsonPreview = DiagnosticsFormat.snapshotJSON(snapshot)
        items.append(
            CheckItem(
                id: "snapshot",
                title: "配置快照",
                state: .ok,
                detail: "配置 v\(snapshot.version) · \(snapshot.providers.count) 个服务 · 约 \(DiagnosticsFormat.byteDescription(jsonPreview))。",
                actionTitle: "复制 JSON",
                action: {
                    UIPasteboard.general.string = jsonPreview
                    appState.showToast(ToastMessage(kind: .success, text: "配置 JSON 已复制"))
                }
            )
        )

        // 9. 网络
        items.append(
            CheckItem(
                id: "network",
                title: "网络连接",
                state: networkState,
                detail: networkDetail,
                actionTitle: "检测",
                action: { checkNetwork() }
            )
        )

        checks = items
    }

    /// 测试当前默认对话服务商。
    func testProvider() {
        guard let provider = appState.defaultChatProvider else {
            providerTestState = .failure
            providerTestDetail = "还没有配置对话服务商。"
            rebuildChecks()
            return
        }
        guard let key = appState.apiKey(for: provider.id), !key.isEmpty else {
            providerTestState = .failure
            providerTestDetail = "服务商「\(provider.name)」还没有填写 API 密钥。"
            rebuildChecks()
            return
        }
        guard provider.supportsChat else {
            providerTestState = .failure
            providerTestDetail = provider.unsupportedChatReason ?? "这个服务商不能用于文本对话。"
            rebuildChecks()
            return
        }

        isTestingProvider = true
        providerTestState = .running
        providerTestDetail = "正在向「\(provider.name)」发一条最小请求…"
        rebuildChecks()

        let started = Date()
        Task {
            var received = ""
            do {
                let stream = ConnectivityProbe.makeHelloStream(config: provider, apiKey: key)
                for try await delta in stream {
                    if !delta.text.isEmpty {
                        received += delta.text
                    }
                    if delta.isFinal { break }
                }
                let elapsed = Date().timeIntervalSince(started)
                let reply = received.trimmingCharacters(in: .whitespacesAndNewlines)
                isTestingProvider = false
                if reply.isEmpty {
                    providerTestState = .warning
                    providerTestDetail = "连接成功但没返回文字（耗时 \(DiagnosticsFormat.seconds(elapsed))）。可以正常使用。"
                } else {
                    providerTestState = .ok
                    providerTestDetail = "连接成功 · 返回：\(DiagnosticsFormat.truncate(reply, limit: 24))（耗时 \(DiagnosticsFormat.seconds(elapsed))）"
                }
            } catch {
                isTestingProvider = false
                providerTestState = .failure
                let message = ErrorPresenter.message(error)
                let suggestion = ErrorPresenter.suggestion(error)
                providerTestDetail = suggestion.map { "\(message)。\($0)" } ?? message
            }
            rebuildChecks()
        }
    }

    /// 检测公网连通性。
    func checkNetwork() {
        networkState = .running
        networkDetail = "正在检测…"
        rebuildChecks()

        Task {
            let result = await ConnectivityProbe.checkNetwork()
            networkState = result.isReachable ? .ok : .failure
            if let latency = result.latency {
                networkDetail = "\(result.detail) · 耗时 \(DiagnosticsFormat.seconds(latency))"
            } else {
                networkDetail = result.detail
            }
            rebuildChecks()
        }
    }

    /// 全部重测（含网络与服务商）。
    func refreshAll() {
        isRefreshing = true
        Haptics.light()
        appState.refreshDerivedState()
        providerTestState = .info
        providerTestDetail = "还没有测试"
        rebuildChecks()

        Task {
            await refreshAsync()
            isRefreshing = false
            Haptics.success()
        }
    }

    /// 异步部分：网络 + 服务商。
    func refreshAsync() async {
        networkState = .running
        networkDetail = "正在检测…"
        rebuildChecks()

        let result = await ConnectivityProbe.checkNetwork()
        networkState = result.isReachable ? .ok : .failure
        if let latency = result.latency {
            networkDetail = "\(result.detail) · 耗时 \(DiagnosticsFormat.seconds(latency))"
        } else {
            networkDetail = result.detail
        }
        rebuildChecks()

        if let provider = appState.defaultChatProvider,
           let key = appState.apiKey(for: provider.id),
           !key.isEmpty,
           provider.supportsChat {
            providerTestState = .running
            providerTestDetail = "正在向「\(provider.name)」发一条最小请求…"
            rebuildChecks()

            let started = Date()
            var received = ""
            do {
                let stream = ConnectivityProbe.makeHelloStream(config: provider, apiKey: key)
                for try await delta in stream {
                    if !delta.text.isEmpty { received += delta.text }
                    if delta.isFinal { break }
                }
                let elapsed = Date().timeIntervalSince(started)
                let reply = received.trimmingCharacters(in: .whitespacesAndNewlines)
                if reply.isEmpty {
                    providerTestState = .warning
                    providerTestDetail = "连接成功但没返回文字（耗时 \(DiagnosticsFormat.seconds(elapsed))）。"
                } else {
                    providerTestState = .ok
                    providerTestDetail = "连接成功 · 返回：\(DiagnosticsFormat.truncate(reply, limit: 24))（耗时 \(DiagnosticsFormat.seconds(elapsed))）"
                }
            } catch {
                providerTestState = .failure
                let message = ErrorPresenter.message(error)
                let suggestion = ErrorPresenter.suggestion(error)
                providerTestDetail = suggestion.map { "\(message)。\($0)" } ?? message
            }
        } else {
            providerTestState = .info
            providerTestDetail = "还没有可测试的对话服务商（需要已配置并有 API 密钥）。"
        }
        rebuildChecks()
    }
}
