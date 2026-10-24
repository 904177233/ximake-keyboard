//
//  SegmentedTabs.swift
//  墨语 · 宿主 App 组件
//
//  分段切换（契约：design/组件库.md §4.3）。
//
import SwiftUI

/// 胶囊分段控件 / 系统分段控件。
struct SegmentedTabs: View {

    /// 一个分段。
    struct Tab: Identifiable, Equatable {
        let id: String
        let title: String
        var badge: Int?

        init(id: String, title: String, badge: Int? = nil) {
            self.id = id
            self.title = title
            self.badge = badge
        }
    }

    /// 外观风格。
    enum Style {
        /// 自绘胶囊（灰底 + 白胶囊滑块）。
        case capsule
        /// 系统 `Picker(.segmented)`。
        case plain
    }

    private let tabs: [Tab]
    @Binding private var selection: String
    private let style: Style

    @Namespace private var namespace

    init(tabs: [Tab], selection: Binding<String>, style: Style = .capsule) {
        self.tabs = tabs
        self._selection = selection
        self.style = style
    }

    var body: some View {
        switch style {
        case .capsule:
            capsuleBody
        case .plain:
            plainBody
        }
    }

    /// 自绘胶囊分段。
    private var capsuleBody: some View {
        HStack(spacing: AppMetrics.hairGap) {
            ForEach(tabs) { tab in
                Button {
                    guard selection != tab.id else { return }
                    Haptics.selection()
                    withAnimation(Theme.Motion.spring) {
                        selection = tab.id
                    }
                } label: {
                    capsuleItem(tab)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityAddTraits(selection == tab.id ? [.isSelected] : [])
            }
        }
        .padding(AppMetrics.hairGap)
        .frame(height: AppMetrics.segmentedHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.surfaceElevated)
        )
    }

    /// 单个胶囊项。
    private func capsuleItem(_ tab: Tab) -> some View {
        HStack(spacing: AppMetrics.hairGap) {
            Text(tab.title)
                .font(AppFont.footnoteStrong)
                .foregroundColor(selection == tab.id ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)

            if let badge = tab.badge, badge > 0 {
                Text("\(badge)")
                    .font(AppFont.caption)
                    .foregroundColor(selection == tab.id ? Theme.accent : Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppMetrics.segmentedHeight - AppMetrics.hairGap * 2)
        .padding(.horizontal, AppMetrics.tightGap)
        .background(
            Group {
                if selection == tab.id {
                    Capsule(style: .continuous)
                        .fill(Theme.surface)
                        .shadow(
                            color: Theme.textPrimary.opacity(Theme.Shadow.chip.opacity),
                            radius: Theme.Shadow.chip.blur,
                            x: 0,
                            y: Theme.Shadow.chip.y
                        )
                        .matchedGeometryEffect(id: "segmented-selection", in: namespace)
                } else {
                    Color.clear
                }
            }
        )
        .contentShape(Capsule(style: .continuous))
    }

    /// 系统分段控件。
    private var plainBody: some View {
        Picker("", selection: $selection) {
            ForEach(tabs) { tab in
                Text(tab.title).tag(tab.id)
            }
        }
        .pickerStyle(SegmentedPickerStyle())
        .accessibilityLabel(Text("分段选择"))
    }
}

#if DEBUG
struct SegmentedTabs_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: AppMetrics.sectionGap) {
            SegmentedTabs(
                tabs: [
                    Tab(id: "all", title: "全部"),
                    Tab(id: "polish", title: "润色"),
                    Tab(id: "translate", title: "翻译", badge: 2)
                ],
                selection: .constant("polish")
            )
            SegmentedTabs(
                tabs: [Tab(id: "a", title: "全部"), Tab(id: "b", title: "自定义")],
                selection: .constant("a"),
                style: .plain
            )
        }
        .padding()
        .background(AppColor.pageBackground)
    }
}
#endif
