//
//  AppStyle.swift
//  墨语 App · 公共样式
//
//  整个 App 就是一张纸加几条细线：不套卡片，不用胶囊，层级靠字重和留白。
//

import SwiftUI

/// 带大标题的页面。
struct AppPage<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(palette.text.color)
                        .padding(.top, 8)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(palette.secondary.color)
                            .lineSpacing(3)
                            .padding(.top, 4)
                    }
                    content()
                        .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    AppToast(text: toast)
                        .padding(.bottom, 14)
                }
            }
        }
    }
}

/// 提示条。
struct AppToast: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(Color(uiColor: .systemBackground))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(palette.text.color)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 24)
    }
}

/// 分组小标题。
struct SectionLabel: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(palette.secondary.color)
            .padding(.top, 24)
            .padding(.bottom, 4)
    }
}

/// 一行：左边标题和说明，右边随意。
struct LineRow<Accessory: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var detail: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15.5))
                    .foregroundColor(palette.text.color)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundColor(palette.secondary.color)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .frame(minHeight: 50)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            palette.line.color.frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }
}

/// 右边的状态文字。
struct StateText: View {
    @Environment(\.palette) private var palette
    let text: String
    var isGood = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: isGood ? .semibold : .regular))
            .foregroundColor(isGood ? palette.accentText.color : palette.secondary.color)
            .lineLimit(1)
    }
}

/// 向右的小箭头。
struct Chevron: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(palette.secondary.color)
    }
}

/// 主按钮。
struct PrimaryButton: View {
    @Environment(\.palette) private var palette
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(palette.onAccent.color)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(palette.accent.color)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 次按钮。
struct SecondaryButton: View {
    @Environment(\.palette) private var palette
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14.5))
                .foregroundColor(palette.text.color)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
