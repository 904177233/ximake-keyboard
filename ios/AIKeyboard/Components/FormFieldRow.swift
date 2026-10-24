//
//  FormFieldRow.swift
//  墨语 · 宿主 App 组件
//
//  表单里的一行：上方小标题（必填带红色星号）+ 下方输入控件。
//  用于 ProviderEditorView / PromptEditorView 等自绘表单。
//
//  契约说明：`design/组件库.md` 未定义此组件，属于本模块在契约之外的补充实现，
//  已记录在 `ios/AIKeyboard/README.md` 的「契约外补充组件」一节。
//

import SwiftUI

/// 表单行容器。
struct FormFieldRow<Content: View>: View {

    /// 行标题。
    let title: String

    /// 是否必填（标题后加红色星号）。
    var isRequired: Bool = false

    /// 右侧说明（可选）。
    var hint: String?

    /// 控件内容。
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        isRequired: Bool = false,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isRequired = isRequired
        self.hint = hint
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
            HStack(spacing: AppMetrics.hairGap) {
                Text(title)
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textSecondary)

                if isRequired {
                    Text("*")
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.danger)
                }

                Spacer(minLength: 0)

                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(AppFont.caption)
                        .foregroundColor(Theme.textTertiary)
                }
            }

            content()
                .frame(minHeight: AppMetrics.fieldHeight, alignment: .leading)
        }
    }
}

#if DEBUG
struct FormFieldRow_Previews: PreviewProvider {
    static var previews: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                FormFieldRow(title: "名称", isRequired: true) {
                    TextField("例如 DeepSeek", text: .constant("DeepSeek"))
                        .font(AppFont.body)
                }
                FormFieldRow(title: "超时", hint: "秒") {
                    Text("30")
                        .font(AppFont.monospaced)
                }
            }
        }
        .padding()
        .background(AppColor.pageBackground)
    }
}
#endif
