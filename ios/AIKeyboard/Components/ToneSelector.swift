//
//  ToneSelector.swift
//  墨语 · 宿主 App 组件
//
//  语气选择器（契约：design/组件库.md §3.6）。
//
import SwiftUI

/// 横向语气选择条。
struct ToneSelector: View {

    /// 契约规定的五种语气，顺序固定。
    static let defaultTones: [String] = ["自然", "简洁", "礼貌", "正式", "热情"]

    private let tones: [String]
    private let selected: String
    private let onSelect: (String) -> Void

    init(
        tones: [String] = ToneSelector.defaultTones,
        selected: String,
        onSelect: @escaping (String) -> Void
    ) {
        self.tones = tones
        self.selected = selected
        self.onSelect = onSelect
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppMetrics.blockGap) {
                ForEach(tones, id: \.self) { tone in
                    PillChip(
                        tone,
                        style: .tone,
                        isSelected: tone == selected,
                        action: { onSelect(tone) }
                    )
                }
            }
            .padding(.horizontal, AppMetrics.pageInset)
        }
        .frame(height: AppMetrics.resultActionHeight)
        .accessibilityLabel(Text("语气选择"))
    }
}

#if DEBUG
struct ToneSelector_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
            ToneSelector(selected: "自然", onSelect: { _ in })
            ToneSelector(selected: "正式", onSelect: { _ in })
        }
        .padding(.vertical)
        .background(AppColor.pageBackground)
    }
}
#endif
