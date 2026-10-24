//
//  PhraseLibraryView.swift
//  墨语 · 宿主 App
//
//  模块职责：快捷短语管理（设置 › 快捷短语 / 键盘主页 › 快捷短语）。
//            列表按「置顶优先」展示，支持新增、编辑、置顶、复制与删除；
//            数据经 SharedBridge.PhraseStore 落到 Shared 层的 PhraseLibrary，
//            与键盘扩展共用同一份存储（有 App Group 时实时共享，否则靠剪贴板搬运）。
//  依赖：SwiftUI、AppState、SurfaceCard / SectionHeader / ListGroup / RowDivider /
//        EmptyState / PrimaryButton / SecondaryButton / PillChip / IconGlyph / FormFieldRow、
//        PhraseStore（SharedBridge）。
//  使用方：KeyboardHomeView / SettingsView。
//

import SwiftUI

/// 快捷短语管理页。
struct PhraseLibraryView: View {

    @EnvironmentObject private var appState: AppState

    /// 本地缓存（每次增删改后从 PhraseStore 重新读）。
    @State private var phrases: [PhraseItem] = []

    /// 编辑目标：新建 / 编辑已有短语。
    @State private var editorRoute: PhraseEditorRoute?

    /// 待删除的短语（用于二次确认）。
    @State private var pendingDelete: PhraseItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                introCard

                if phrases.isEmpty {
                    emptyCard
                } else {
                    phraseSection
                }

                newPhraseButton
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("快捷短语")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    editorRoute = .create
                } label: {
                    IconGlyph(
                        symbol: "plus",
                        fallback: "＋",
                        size: AppMetrics.glyphSize,
                        weight: .semibold,
                        tint: Theme.accent
                    )
                }
                .accessibilityLabel(Text("新建短语"))
            }
        }
        .sheet(item: $editorRoute) { route in
            NavigationStack {
                PhraseEditorView(item: route.item) { saved in
                    editorRoute = nil
                    save(saved)
                }
            }
        }
        .alert(item: $pendingDelete) { item in
            Alert(
                title: Text("删除这条短语？"),
                message: Text(deleteMessage(item)),
                primaryButton: .destructive(Text("删除")) {
                    delete(item)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onAppear(perform: reload)
    }

    // MARK: - 说明卡

    /// 顶部说明：讲清「触发词」与「占位符」两件事。
    private var introCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                Text("怎么用")
                    .font(AppFont.footnoteStrong)
                    .foregroundColor(Theme.textSecondary)

                Text("在键盘里输入触发词再敲空格，就会展开成整段文字。没设触发词的短语，可以从键盘的短语面板里手动选。")
                    .font(AppFont.body)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("正文支持 {date} 今天日期、{time} 当前时间、{clipboard} 剪贴板内容，发送时才展开。")
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    // i18n-ignore：这里是短语占位符的字面量，不是英文 UI 文案。
                    .accessibilityLabel(Text("正文支持日期、时间、剪贴板三种占位符"))
            }
        }
    }

    // MARK: - 列表

    /// 短语列表分组。
    private var phraseSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(
                title: "我的短语",
                footnote: "\(phrases.count) 条 · 置顶优先",
                trailing: pinnedCount > 0 ? "置顶 \(pinnedCount) 条" : nil
            )

            ListGroup(footer: "左滑不需要，点右侧「⋯」可以置顶、复制、编辑或删除。") {
                ForEach(Array(phrases.enumerated()), id: \.element.id) { index, item in
                    phraseRow(item)
                    if index < phrases.count - 1 {
                        RowDivider()
                    }
                }
            }
        }
    }

    /// 单条短语。
    private func phraseRow(_ item: PhraseItem) -> some View {
        HStack(spacing: AppMetrics.rowGap) {
            Button {
                editorRoute = .edit(item)
            } label: {
                rowContent(item)
            }
            .buttonStyle(PlainButtonStyle())

            actionsMenu(item)
        }
        .padding(.horizontal, AppMetrics.cardPadding)
        .frame(minHeight: AppMetrics.rowHeightSubtitle)
    }

    /// 行主体：图标 + 触发词 + 正文摘要。
    private func rowContent(_ item: PhraseItem) -> some View {
        HStack(spacing: AppMetrics.rowGap) {
            RoundedRectangle(cornerRadius: AppMetrics.iconTileRadius, style: .continuous)
                .fill(item.isPinned ? AppColor.warningWash : AppColor.successWash)
                .frame(width: AppMetrics.iconTileSize, height: AppMetrics.iconTileSize)
                .overlay(
                    IconGlyph(
                        symbol: item.isPinned ? "pin.fill" : "text.badge.plus",
                        fallback: item.isPinned ? "📌" : "📝",
                        size: AppMetrics.glyphSizeSmall,
                        weight: .semibold,
                        tint: item.isPinned ? Theme.warning : Theme.success
                    )
                )

            VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                HStack(spacing: AppMetrics.tightGap) {
                    Text(keyTitle(item))
                        .font(AppFont.headline.weight(.regular))
                        .foregroundColor(item.key.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)

                    if item.isPinned {
                        PillChip("置顶", style: .tag, action: {})
                            .allowsHitTesting(false)
                    }
                }

                Text(textPreview(item))
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 行尾操作菜单。
    private func actionsMenu(_ item: PhraseItem) -> some View {
        Menu {
            Button {
                togglePin(item)
            } label: {
                Label(item.isPinned ? "取消置顶" : "置顶", systemImage: item.isPinned ? "pin.slash" : "pin")
            }

            Button {
                UIPasteboard.general.string = item.text
                appState.showToast(ToastMessage(kind: .success, text: "短语正文已复制"))
                Haptics.success()
            } label: {
                Label("复制正文", systemImage: "doc.on.doc")
            }

            Button {
                editorRoute = .edit(item)
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Button(role: .destructive) {
                pendingDelete = item
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            IconGlyph(
                symbol: "ellipsis.circle",
                fallback: "⋯",
                size: AppMetrics.glyphSize,
                tint: Theme.textSecondary
            )
            .frame(width: AppMetrics.minTapHeight, height: AppMetrics.minTapHeight)
            .contentShape(Rectangle())
        }
    }

    // MARK: - 空态与新建

    /// 空态。
    private var emptyCard: some View {
        SurfaceCard {
            EmptyState(
                symbol: "text.badge.plus",
                fallbackEmoji: "📝",
                title: "还没有短语",
                message: "把常用的地址、回复、签名存成短语，键盘里输入触发词就能整段展开。",
                actionTitle: "新建短语",
                action: { editorRoute = .create }
            )
        }
    }

    /// 底部新建按钮。
    private var newPhraseButton: some View {
        PrimaryButton(
            title: "新建短语",
            systemImage: "plus",
            tone: .accent,
            size: .medium,
            fullWidth: true
        ) {
            editorRoute = .create
        }
    }

    // MARK: - 派生文案

    /// 置顶条数。
    private var pinnedCount: Int {
        phrases.filter(\.isPinned).count
    }

    /// 标题：有触发词就显示「触发词 →」，否则显示「无触发词」。
    private func keyTitle(_ item: PhraseItem) -> String {
        let trimmed = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "无触发词" : "\(trimmed) →"
    }

    /// 正文摘要（换行压成空格，超过 40 字截断）。
    private func textPreview(_ item: PhraseItem) -> String {
        let raw = item.text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 40
        guard raw.count > limit else { return raw }
        let end = raw.index(raw.startIndex, offsetBy: limit)
        return String(raw[..<end]) + "…"
    }

    /// 删除确认框正文。
    private func deleteMessage(_ item: PhraseItem) -> String {
        let trimmed = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "这条短语" : "「\(trimmed)」"
        return "删除后无法恢复，键盘里也将无法再展开 \(title)。"
    }

    // MARK: - 逻辑

    /// 从存储重新读取。
    private func reload() {
        phrases = PhraseStore.items
        appState.refreshPhraseCount()
    }

    /// 保存（新增或更新）。
    private func save(_ item: PhraseItem) {
        PhraseStore.upsert(item)
        reload()
        appState.showToast(ToastMessage(kind: .success, text: "短语已保存"))
        Haptics.success()
    }

    /// 置顶 / 取消置顶。
    private func togglePin(_ item: PhraseItem) {
        var updated = item
        updated.isPinned.toggle()
        PhraseStore.upsert(updated)
        reload()
        Haptics.selection()
        appState.showToast(
            ToastMessage(kind: .info, text: updated.isPinned ? "已置顶" : "已取消置顶")
        )
    }

    /// 删除。
    private func delete(_ item: PhraseItem) {
        PhraseStore.remove(id: item.id)
        reload()
        Haptics.warning()
        appState.showToast(ToastMessage(kind: .info, text: "短语已删除"))
    }
}

// MARK: - 编辑目标

/// 短语编辑入口：新建或编辑已有短语。
private enum PhraseEditorRoute: Identifiable {

    /// 新建。
    case create

    /// 编辑已有短语。
    case edit(PhraseItem)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .edit(let item):
            return item.id
        }
    }

    /// 传给编辑页的短语；新建为 nil。
    var item: PhraseItem? {
        switch self {
        case .create:
            return nil
        case .edit(let item):
            return item
        }
    }
}

// MARK: - 短语编辑页

/// 新建 / 编辑一条快捷短语（Sheet）。
private struct PhraseEditorView: View {

    /// 编辑中的短语；nil 表示新建。
    private let original: PhraseItem?

    /// 保存回调。
    private let onSave: (PhraseItem) -> Void

    @State private var key: String
    @State private var text: String

    @Environment(\.dismiss) private var dismiss

    /// 可插入的占位符。
    private static let placeholderTokens = ["{date}", "{time}", "{clipboard}"]

    init(item: PhraseItem?, onSave: @escaping (PhraseItem) -> Void) {
        self.original = item
        self.onSave = onSave
        _key = State(initialValue: item?.key ?? "")
        _text = State(initialValue: item?.text ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                basicSection
                placeholderSection
                hintSection
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.vertical, AppMetrics.cardPadding)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle(original == nil ? "新建短语" : "编辑短语")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { dismiss() }
                    .foregroundColor(Theme.textSecondary)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") { save() }
                    .font(AppFont.footnoteStrong)
                    .foregroundColor(canSave ? Theme.accent : Theme.textTertiary)
                    .disabled(!canSave)
            }
        }
    }

    // MARK: - 表单

    /// 触发词 + 正文。
    private var basicSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "内容", footnote: "触发词可留空")

            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                    FormFieldRow(title: "触发词", hint: "不超过 8 个字") {
                        TextField("例如 dz", text: $key)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(AppFont.body)
                            .foregroundColor(Theme.textPrimary)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .padding(.horizontal, AppMetrics.tightGap)
                            .frame(minHeight: AppMetrics.fieldHeight)
                            .background(inputBackground)
                    }

                    FormFieldRow(title: "短语正文", isRequired: true) {
                        PhraseTextEditor(text: $text, minHeight: AppMetrics.textEditorMinHeight)
                            .background(inputBackground)
                    }
                }
            }
        }
    }

    /// 占位符快捷插入。
    private var placeholderSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "插入占位符", footnote: "发送时才替换成真实内容")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppMetrics.tightGap) {
                    ForEach(Self.placeholderTokens, id: \.self) { token in
                        PillChip(token, style: .tag) {
                            text += token
                            Haptics.light()
                        }
                    }
                }
            }
        }
    }

    /// 底部提示。
    private var hintSection: some View {
        Text("示例：触发词「dz」+ 正文「我的地址是：杭州市西湖区…」。在键盘里输入 dz 再敲空格即可展开。")
            .font(AppFont.caption)
            .foregroundColor(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 输入框的统一底色。
    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
            .fill(Theme.surfaceElevated)
    }

    // MARK: - 逻辑

    /// 正文非空即可保存。
    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 保存并关闭。
    private func save() {
        guard canSave else { return }
        let item = PhraseItem(
            id: original?.id ?? UUID().uuidString,
            key: key.trimmingCharacters(in: .whitespacesAndNewlines),
            text: text,
            isPinned: original?.isPinned ?? false
        )
        onSave(item)
        dismiss()
    }
}

// MARK: - 多行输入

/// 带占位符提示的多行输入框。
private struct PhraseTextEditor: View {

    @Binding var text: String

    /// 最小高度。
    let minHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("例如：我的地址是杭州市西湖区…")
                    .font(AppFont.body)
                    .foregroundColor(Theme.textPlaceholder)
                    .padding(.top, AppMetrics.blockGap)
                    .padding(.leading, AppMetrics.tightGap)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(AppFont.body)
                .foregroundColor(Theme.textPrimary)
                .scrollContentBackgroundHiddenCompat()
                .frame(minHeight: minHeight)
        }
    }
}

#if DEBUG
struct PhraseLibraryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PhraseLibraryView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
