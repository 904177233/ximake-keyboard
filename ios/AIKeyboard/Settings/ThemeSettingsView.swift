//
//  ThemeSettingsView.swift
//  墨语 · 宿主 App
//
//  模块职责：主题与小形象设置页 —— 6 套双色主题切换、自定义形象从相册/剪贴板导入、
//  键盘右下角形象的显示开关，以及一块实时跟随当前主题的键盘示意图预览。
//  依赖：SwiftUI、PhotosUI、UIKit；Shared 层 `AppTheme` / `ThemeStore` / `SharedStore`；
//        Components 层 SurfaceCard / SectionHeader / ListGroup / SettingsRow / RowDivider /
//        IconGlyph / Haptics；同目录 `ThemePreviewCard` / `MascotImageCropper`。
//  使用方：AppearanceView（设置 › 语气与外观 › 主题与形象）。
//  规范依据：design/05-主题与小形象规范.md §4.2、§5.1。
//

import PhotosUI
import SwiftUI
import UIKit

/// 主题与小形象设置页。
///
/// 主题切换只影响本页预览与 `ThemeStore` 里持久化的选择，**不改 `Theme` 的静态常量**
/// （`Theme.accent` 等保持编译期常量语义，键盘侧渲染时读取 `AppTheme` 覆盖那 4 处主色）。
/// 页面内用 `@State` 持有当前主题副本，选主题后立刻刷新预览；不引入全局 `ThemeCenter`，
/// 因为本页是唯一修改主题的宿主 App 入口，局部状态足够且更轻。
struct ThemeSettingsView: View {

    // MARK: - 依赖与状态

    @EnvironmentObject private var appState: AppState

    /// 当前生效主题（选中后立即可见地刷新预览与卡片勾选）。
    @State private var current: AppTheme = ThemeStore.shared.currentTheme
    /// 自定义形象 PNG 数据（供预览渲染）。
    @State private var mascotData: Data? = ThemeStore.shared.customMascotData
    /// 自定义形象显示名。
    @State private var mascotName: String = ThemeStore.shared.customMascotName
    /// 键盘右下角是否显示形象的存储键。
    ///
    /// 与键盘扩展约定一致（`moyu.theme.showsMascot`），将来开启 App Group 即可自动打通；
    /// 无 App Group 时宿主与扩展各自保存一份（已知降级）。
    private static let showsMascotKey = "moyu.theme.showsMascot"

    /// 键盘右下角是否显示形象。
    ///
    /// 存储走 `SharedStore`（与 `ThemeStore` 同一套三级存储），键名与键盘扩展约定一致。
    @State private var showsMascot: Bool = SharedStore.shared.bool(forKey: ThemeSettingsView.showsMascotKey, default: true)
    /// 是否正在展示系统相册选择器。
    @State private var showsPhotoPicker = false
    /// 相册选择结果。
    @State private var pickedItem: PhotosPickerItem?
    /// 是否正在读取/裁切图片（防重复点击）。
    @State private var isImporting = false
    /// 导入失败的提示（nil 表示无错误）。
    @State private var importFailure: ImportFailure?

    // MARK: - 布局常量（全部由 Theme 派生）

    /// 预览卡宽度：320pt。
    private var previewWidth: CGFloat { Theme.Spacing.xl * 20 }
    /// 预览卡高度：212pt。
    private var previewHeight: CGFloat { Theme.Spacing.xl * 13 + Theme.Spacing.sm }
    /// 形象预览尺寸：22pt。
    private var mascotPreviewSize: CGFloat { Theme.Spacing.xl + Theme.Spacing.md - Theme.Spacing.xs }

    // MARK: - 页面

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                previewSection
                if let failure = importFailure {
                    failureCard(failure)
                }
                themeSection
                mascotSection
                footnoteSection
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("主题与形象")
        .navigationBarTitleDisplayMode(.inline)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .photosPicker(isPresented: $showsPhotoPicker, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { newValue in
            guard let item = newValue else { return }
            pickedItem = nil
            Task { await importFromPhotoPicker(item) }
        }
    }

    // MARK: - 预览区

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(
                title: "预览",
                footnote: "主色只出现在候选栏首选字、AI 条选中胶囊、回车键、右下角形象这 4 处"
            )

            SurfaceCard(style: .elevated, padding: AppMetrics.rowVPadding) {
                VStack(spacing: AppMetrics.tightGap) {
                    ThemePreviewCard(
                        theme: current,
                        mascotData: mascotData,
                        showsMascot: showsMascot
                    )
                    .frame(width: previewWidth, height: previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous))

                    Text(current.name)
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 主题网格

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "主题", footnote: "每套主题 = 一个主色 + 一个浅底，深色模式自动跟随")

            LazyVGrid(columns: themeColumns, spacing: AppMetrics.blockGap) {
                ForEach(displayedThemes) { theme in
                    themeCell(theme)
                }
            }
        }
    }

    /// 网格里展示的主题：6 个内置预设；若已导入过自定义形象，再补一张「我的形象」卡。
    private var displayedThemes: [AppTheme] {
        var themes = AppTheme.allPresets
        if ThemeStore.shared.hasCustomMascot {
            themes.append(AppTheme.custom(mascotName: mascotName))
        }
        return themes
    }

    private var themeColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: AppMetrics.blockGap),
            GridItem(.flexible(), spacing: AppMetrics.blockGap)
        ]
    }

    /// 单个主题卡：双色块 + 名称 + 品牌备注 + 选中勾。
    private func themeCell(_ theme: AppTheme) -> some View {
        let selected = current.id == theme.id
        let swatchSide = AppMetrics.glyphSize + AppMetrics.tightGap

        return Button {
            selectTheme(theme)
        } label: {
            VStack(alignment: .leading, spacing: AppMetrics.tightGap) {
                HStack(spacing: AppMetrics.tightGap) {
                    RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                        .fill(theme.accent)
                        .frame(width: swatchSide, height: swatchSide)
                    RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                        .fill(theme.tint)
                        .frame(width: swatchSide, height: swatchSide)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                                .strokeBorder(Theme.separatorOpaque, lineWidth: AppMetrics.hairline)
                        )
                }

                HStack(spacing: AppMetrics.hairGap) {
                    Text(theme.name)
                        .font(AppFont.headline)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        IconGlyph(
                            symbol: "checkmark.circle.fill",
                            size: AppMetrics.glyphSize,
                            tint: Theme.accent
                        )
                    }
                }

                Text(theme.brandNote ?? "自己导入的形象")
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(AppMetrics.rowVPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.surface,
                in: RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous)
                    .strokeBorder(
                        selected ? Theme.accent : Theme.separatorOpaque,
                        lineWidth: selected ? AppMetrics.hairline * 4 : AppMetrics.hairline
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Text("\(theme.name)主题"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - 小形象

    private var mascotSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "小形象", footnote: "显示在键盘右下角，可以放你喜欢的任何图片")

            ListGroup(footer: "图片会裁成正方形并缩到 \(Int(MascotImageCropper.side))×\(Int(MascotImageCropper.side))，只存在这台手机里。") {
                mascotPreviewRow
                RowDivider(hasIcon: false)
                SettingsRow(
                    icon: IconSpec(symbol: "photo.on.rectangle", tint: Theme.accent),
                    title: "从相册选择",
                    subtitle: "用系统相册选择器，不需要相册权限",
                    accessory: .chevron
                ) {
                    importFailure = nil
                    showsPhotoPicker = true
                }
                RowDivider()
                SettingsRow(
                    icon: IconSpec(symbol: "doc.on.clipboard", tint: Theme.success),
                    title: "从剪贴板粘贴",
                    subtitle: "iOS 会问一次是否允许粘贴，点允许即可",
                    accessory: .chevron
                ) {
                    importFromClipboard()
                }
                RowDivider()
                SettingsRow(
                    icon: IconSpec(symbol: "keyboard", tint: Theme.warning),
                    title: "在键盘右下角显示",
                    subtitle: showsMascot ? "关闭后空格键会变宽一点" : "已隐藏，空格键占满整行",
                    accessory: .toggle(mascotVisible)
                )
            }
        }
    }

    /// 当前形象预览行：22pt 预览 + 名称 + 「更换」。
    private var mascotPreviewRow: some View {
        Button {
            importFailure = nil
            showsPhotoPicker = true
        } label: {
            HStack(spacing: AppMetrics.rowGap) {
                mascotPreview(size: mascotPreviewSize)

                VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                    Text(mascotName)
                        .font(AppFont.headline.weight(.regular))
                        .foregroundColor(Theme.textPrimary)
                    Text(mascotData == nil ? "还没有自定义形象，点「更换」选一张" : "点「更换」可以重新选一张")
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.textSecondary)
                }

                Spacer(minLength: AppMetrics.tightGap)

                Text("更换")
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.accent)
            }
            .padding(.horizontal, AppMetrics.cardPadding)
            .frame(minHeight: AppMetrics.rowHeightSubtitle)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// 圆形形象预览（无自定义图时用几何符号占位）。
    private func mascotPreview(size: CGFloat) -> some View {
        ZStack {
            Circle().fill(AppColor.accentWash)
            if let data = mascotData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                IconGlyph(symbol: "theatermasks.fill", size: size, tint: Theme.accent)
            }
        }
        .frame(width: size, height: size)
    }

    private var mascotVisible: Binding<Bool> {
        Binding(
            get: { showsMascot },
            set: { newValue in
                showsMascot = newValue
                SharedStore.shared.setBool(newValue, forKey: Self.showsMascotKey)
                Haptics.selection()
            }
        )
    }

    // MARK: - 底部说明

    private var footnoteSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.tightGap) {
            Text("形象只存在这台手机里，不会上传。")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
            Text("想用网上的角色图？注意版权 —— 详见 docs/11-主题与AI形象版权边界。")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 导入失败提示卡。
    private func failureCard(_ failure: ImportFailure) -> some View {
        SurfaceCard(padding: AppMetrics.rowVPadding) {
            HStack(alignment: .top, spacing: AppMetrics.rowGap) {
                IconGlyph(
                    symbol: "exclamationmark.triangle.fill",
                    size: AppMetrics.glyphSize,
                    tint: Theme.warning
                )
                VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                    Text(failure.title)
                        .font(AppFont.headline)
                        .foregroundColor(Theme.textPrimary)
                    Text(failure.message)
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    importFailure = nil
                } label: {
                    IconGlyph(
                        symbol: "xmark.circle.fill",
                        size: AppMetrics.glyphSize,
                        tint: Theme.textTertiary
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - 动作：选主题

    private func selectTheme(_ theme: AppTheme) {
        guard current.id != theme.id else { return }
        ThemeStore.shared.currentThemeID = theme.id
        current = ThemeStore.shared.currentTheme
        Haptics.selection()
    }

    // MARK: - 动作：导入形象

    @MainActor
    private func importFromPhotoPicker(_ item: PhotosPickerItem) async {
        guard !isImporting else { return }
        isImporting = true
        importFailure = nil
        defer { isImporting = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                importFailure = ImportFailure(
                    title: "读取失败",
                    message: "这个文件读不出图片数据，换一张试试。"
                )
                return
            }
            guard data.count <= MascotImageCropper.maxSourceBytes else {
                importFailure = ImportFailure(
                    title: "图片太大",
                    message: "请选小一点的图片（上限 \(MascotImageCropper.maxSourceDescription)）。"
                )
                return
            }
            guard let image = UIImage(data: data) else {
                importFailure = ImportFailure(
                    title: "不是图片",
                    message: "这个文件不是常见的图片格式，换一张试试。"
                )
                return
            }
            applyImportedImage(image)
        } catch {
            importFailure = ImportFailure(
                title: "读取图片失败",
                message: error.localizedDescription
            )
        }
    }

    private func importFromClipboard() {
        importFailure = nil
        guard let image = UIPasteboard.general.image else {
            importFailure = ImportFailure(
                title: "剪贴板里没有图片",
                message: "先复制一张图片（比如截图），再回来点这里。"
            )
            return
        }
        applyImportedImage(image)
    }

    /// 裁切为 512×512 PNG 后写入 `ThemeStore`，并自动切到自定义主题。
    private func applyImportedImage(_ image: UIImage) {
        guard let png = MascotImageCropper.squarePNG(from: image) else {
            importFailure = ImportFailure(
                title: "保存失败",
                message: "这张图暂时无法处理，换一张试试。"
            )
            return
        }
        guard png.count <= MascotImageCropper.maxStoredBytes else {
            importFailure = ImportFailure(
                title: "图片太大",
                message: "裁切后仍然超过 \(MascotImageCropper.maxStoredDescription)，换一张试试。"
            )
            return
        }

        let isBlank = MascotImageCropper.looksBlank(pngData: png)
        let store = ThemeStore.shared
        store.customMascotData = png
        store.customMascotName = mascotName
        store.currentThemeID = AppTheme.customID

        mascotData = png
        mascotName = store.customMascotName
        current = store.currentTheme
        importFailure = nil
        Haptics.success()
        appState.showToast(
            ToastMessage(
                kind: isBlank ? .warning : .success,
                text: isBlank ? "已导入，但这张图看不出内容" : "形象已更新",
                detail: isBlank ? "换一张有内容的图片会更清楚。" : "已切换到「自定义」主题。"
            )
        )
    }
}

// MARK: - 辅助类型

/// 导入失败提示。
private struct ImportFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#if DEBUG
struct ThemeSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ThemeSettingsView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
