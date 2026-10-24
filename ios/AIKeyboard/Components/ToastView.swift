//
//  ToastView.swift
//  墨语 · 宿主 App 组件
//
//  轻量悬浮提示（顶部滑下，2.2 秒自动消失）。
//
import SwiftUI

/// 悬浮提示卡片。
struct ToastView: View {

    let message: ToastMessage

    var body: some View {
        HStack(alignment: .top, spacing: AppMetrics.rowGap) {
            Image(systemName: iconName)
                .font(AppFont.headline)
                .foregroundColor(tint)

            VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                Text(message.text)
                    .font(AppFont.headline)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = message.detail {
                    Text(detail)
                        .font(AppFont.caption)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(AppMetrics.cardPadding)
        .background(
            GlassSurface(level: .bar, cornerRadius: AppMetrics.cardRadius, showHighlight: false) {
                Theme.surface.opacity(0.35)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: AppMetrics.hairline * 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous))
        .shadow(
            color: Theme.textPrimary.opacity(Theme.Shadow.glass.opacity),
            radius: Theme.Shadow.glass.blur,
            x: 0,
            y: Theme.Shadow.glass.y
        )
        .padding(.horizontal, AppMetrics.pageInset)
    }

    private var iconName: String {
        switch message.kind {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch message.kind {
        case .success: return Theme.success
        case .info: return Theme.accent
        case .warning: return Theme.warning
        case .failure: return Theme.danger
        }
    }
}

/// 给任意视图挂上 Toast 能力。
private struct ToastOverlayModifier: ViewModifier {

    @Binding var message: ToastMessage?

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            if let message {
                ToastView(message: message)
                    .padding(.top, AppMetrics.tightGap)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
                    .onTapGesture { self.message = nil }
                    .task(id: message.id) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        if !Task.isCancelled {
                            withAnimation(.easeOut(duration: Theme.Motion.fast)) {
                                self.message = nil
                            }
                        }
                    }
            }
        }
        .animation(Theme.Motion.spring, value: message?.id)
    }
}

extension View {
    /// 挂载 Toast 浮层。
    func toastOverlay(_ message: Binding<ToastMessage?>) -> some View {
        modifier(ToastOverlayModifier(message: message))
    }
}

#if DEBUG
struct ToastView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            AppColor.pageBackground.ignoresSafeArea()
            VStack(spacing: AppMetrics.blockGap) {
                ToastView(message: ToastMessage(kind: .success, text: "已复制到系统剪贴板", detail: "请打开键盘 → ⚙️ → 导入配置"))
                ToastView(message: ToastMessage(kind: .failure, text: "连接失败", detail: "API Key 无效或已过期"))
            }
        }
    }
}
#endif
