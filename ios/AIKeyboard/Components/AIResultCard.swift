//
//  AIResultCard.swift
//  墨语 · 宿主 App 组件
//
//  AI 结果卡（契约：design/组件库.md §3.5）。
//  五种状态：流式文本 / 已完成文本 / 失败 / 生图绘制中 / 已出图。
//  宿主 App 的「AI 试验场」与键盘扩展的 AI 面板共用这一套视觉。
//
import SwiftUI

/// AI 结果卡。
struct AIResultCard: View {

    /// 结果状态。
    ///
    /// 命名说明：**不能叫 `State`**。嵌套在 `View` 里的 `enum State` 会遮蔽
    /// SwiftUI 的 `@State` 属性包装器，导致 `@State private var ...` 报
    /// `enum 'State' cannot be used as an attribute`（CI 实测）。
    enum ResultState: Equatable {
        /// 流式输出中。
        case streaming(String)
        /// 已完成。
        case done(String)
        /// 失败。
        case failed(AIErrorViewData)
        /// 生图绘制中。
        case imageGenerating(ImageProgress)
        /// 已出图。
        case image(ImageResultViewData)
    }

    var feature: AIFeature
    var state: ResultState
    var providerName: String
    var canRetry: Bool
    var onInsert: (() -> Void)?
    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?
    var onRetry: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    /// 「保存到相册」动作（仅 `.image` 状态显示；nil 表示不展示该按钮）。
    ///
    /// 声明为 `@MainActor` 的 async 闭包：按钮点击后卡片把自己切到加载态，
    /// 等闭包返回再恢复，避免用户连点重复写入相册。
    var onSaveToAlbum: (@MainActor () async -> Void)?

    /// 生图开始时刻，用于本地每秒计时。
    @State private var imageStartedAt = Date()

    /// 正在保存到相册（按钮加载态）。
    @State private var isSavingToAlbum = false

    init(
        feature: AIFeature,
        state: ResultState,
        providerName: String = "",
        canRetry: Bool = true,
        onInsert: (() -> Void)? = nil,
        onCopy: (() -> Void)? = nil,
        onEdit: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        onSaveToAlbum: (@MainActor () async -> Void)? = nil
    ) {
        self.feature = feature
        self.state = state
        self.providerName = providerName
        self.canRetry = canRetry
        self.onInsert = onInsert
        self.onCopy = onCopy
        self.onEdit = onEdit
        self.onRetry = onRetry
        self.onCancel = onCancel
        self.onClose = onClose
        self.onSaveToAlbum = onSaveToAlbum
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RowDivider(hasIcon: false)
            content
            actionBar
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous))
        .transition(.opacity.combined(with: .offset(y: AppMetrics.blockGap)))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: AppMetrics.tightGap) {
            IconGlyph(
                symbol: FeatureGlyph.symbol(for: feature),
                fallback: FeatureGlyph.fallback(for: feature),
                size: AppMetrics.glyphSizeSmall,
                weight: .semibold,
                tint: Theme.accent
            )
            Text(feature.title)
                .font(AppFont.footnoteStrong)
                .foregroundColor(Theme.textPrimary)
            if !providerName.isEmpty {
                Text("·")
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textTertiary)
                Text(providerName)
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AppMetrics.tightGap)
            statusLabel
            if let onClose {
                Button(action: onClose) {
                    IconGlyph(
                        symbol: "xmark",
                        fallback: "×",
                        size: AppMetrics.glyphSizeSmall - AppMetrics.hairGap,
                        weight: .semibold,
                        tint: Theme.textTertiary
                    )
                    .frame(width: AppMetrics.minTapHeight, height: AppMetrics.minTapHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(Text("关闭结果"))
            }
        }
        .padding(.leading, AppMetrics.cardPadding)
        .padding(.trailing, AppMetrics.hairGap)
        .frame(minHeight: AppMetrics.resultActionHeight)
    }

    /// 右上方状态文字。
    @ViewBuilder
    private var statusLabel: some View {
        switch state {
        case .streaming:
            Text("生成中")
                .font(AppFont.caption)
                .foregroundColor(Theme.accent)
        case .done:
            Text("已完成")
                .font(AppFont.caption)
                .foregroundColor(Theme.success)
        case .failed:
            Text("失败")
                .font(AppFont.caption)
                .foregroundColor(Theme.danger)
        case .imageGenerating:
            Text("绘制中")
                .font(AppFont.caption)
                .foregroundColor(Theme.accent)
        case .image:
            Text("已完成")
                .font(AppFont.caption)
                .foregroundColor(Theme.success)
        }
    }

    // MARK: - 正文

    @ViewBuilder
    private var content: some View {
        switch state {
        case .streaming(let text):
            StreamingText(
                text: text,
                isStreaming: true,
                font: AppFont.result,
                maxHeight: AppMetrics.streamingMaxHeight
            )
            .padding(AppMetrics.cardPadding)

        case .done(let text):
            StreamingText(
                text: text,
                isStreaming: false,
                font: AppFont.result,
                maxHeight: 0
            )
            .padding(AppMetrics.cardPadding)

        case .failed(let data):
            failureBody(data)

        case .imageGenerating(let progress):
            imageGeneratingBody(progress)

        case .image(let result):
            imageBody(result)
        }
    }

    /// 失败态：错误条 + 建议。
    private func failureBody(_ data: AIErrorViewData) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            ErrorBanner(
                severity: .error,
                title: data.title,
                message: data.message ?? data.suggestion
            )
            if let suggestion = data.suggestion, data.message != nil {
                Text(suggestion)
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppMetrics.cardPadding)
            }
        }
        .padding(.vertical, AppMetrics.cardPadding)
    }

    /// 生图绘制中：进度环 + 已等待秒数，每秒刷新。
    private func imageGeneratingBody(_ progress: ImageProgress) -> some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let liveElapsed = max(progress.elapsed, context.date.timeIntervalSince(imageStartedAt))
            let fraction = liveElapsed >= progress.expected.lowerBound
                ? 0.9
                : min(max(liveElapsed / max(progress.expected.lowerBound, 0.1), 0.02), 0.9)
            let seconds = Int(liveElapsed.rounded(.down))
            let overdue = liveElapsed > progress.expected.upperBound

            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                HStack(alignment: .center, spacing: AppMetrics.rowGap) {
                    ProgressRing(fraction: fraction)

                    VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                        Text("绘制中… 已等待 \(seconds) 秒")
                            .font(AppFont.body)
                            .foregroundColor(Theme.textPrimary)
                        Text("预计 \(Int(progress.expected.lowerBound))–\(Int(progress.expected.upperBound)) 秒 · \(progress.stage.title)")
                            .font(AppFont.caption)
                            .foregroundColor(Theme.textSecondary)
                        if overdue {
                            Text("仍在绘制，可继续等待")
                                .font(AppFont.caption)
                                .foregroundColor(Theme.warning)
                        }
                    }

                    Spacer(minLength: 0)
                }

                if !progress.prompt.isEmpty {
                    Text("提示词：\(progress.prompt)")
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(AppMetrics.cardPadding)
        }
        .onAppear { imageStartedAt = Date() }
    }

    /// 已出图：缩略图 + 提示词。
    private func imageBody(_ result: ImageResultViewData) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            thumbnail(result)
            if !result.sizeDescription.isEmpty {
                Text(result.sizeDescription)
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            if !result.prompt.isEmpty {
                Text("提示词：\(result.prompt)")
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }
            Text(onSaveToAlbum == nil
                 ? "复制后回到聊天窗口长按输入框粘贴"
                 : "复制后回到聊天窗口长按输入框粘贴，也可以直接保存到相册。")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppMetrics.cardPadding)
    }

    /// 图片缩略图。
    @ViewBuilder
    private func thumbnail(_ result: ImageResultViewData) -> some View {
        Group {
            if let data = result.imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let url = result.remoteURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    case .failure:
                        imagePlaceholder(text: "图片加载失败")
                    case .empty:
                        imagePlaceholder(text: "加载中…")
                    @unknown default:
                        imagePlaceholder(text: "图片不可用")
                    }
                }
            } else {
                imagePlaceholder(text: "图片不可用")
            }
        }
        .frame(maxWidth: AppMetrics.imageMaxWidth, maxHeight: AppMetrics.imageMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.thumbnailRadius, style: .continuous))
    }

    /// 图片占位。
    private func imagePlaceholder(text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppMetrics.thumbnailRadius, style: .continuous)
                .fill(Theme.surfaceElevated)
            Text(text)
                .font(AppFont.caption)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(width: AppMetrics.imageMaxWidth, height: AppMetrics.imageMaxHeight)
    }

    // MARK: - 动作条

    @ViewBuilder
    private var actionBar: some View {
        switch state {
        case .streaming:
            actionRow {
                SecondaryButton(title: "取消", tone: .neutral, size: .small, action: { onCancel?() })
            }

        case .done:
            actionRow {
                SecondaryButton(title: "复制", tone: .neutral, size: .small, action: { onCopy?() })
                SecondaryButton(title: "保存为短语", tone: .neutral, size: .small, action: { onEdit?() })
                if canRetry {
                    SecondaryButton(title: "重试", tone: .neutral, size: .small, action: { onRetry?() })
                }
                Spacer(minLength: 0)
            }

        case .failed:
            actionRow {
                if canRetry {
                    SecondaryButton(title: "重试", tone: .neutral, size: .small, action: { onRetry?() })
                }
                SecondaryButton(title: "关闭", tone: .neutral, size: .small, action: { onClose?() })
                Spacer(minLength: 0)
            }

        case .imageGenerating:
            actionRow {
                SecondaryButton(title: "取消", tone: .neutral, size: .small, action: { onCancel?() })
                Spacer(minLength: 0)
            }

        case .image:
            actionRow {
                SecondaryButton(title: "复制图片", tone: .neutral, size: .small, action: { onCopy?() })
                saveToAlbumButton
                if canRetry {
                    SecondaryButton(title: "重试", tone: .neutral, size: .small, action: { onRetry?() })
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 「保存到相册」按钮（仅当外部提供了动作时出现）。
    ///
    /// 权限申请发生在用户点下这个按钮之后（`PhotoLibrarySaver.save` 内部），
    /// 卡片本身不做任何权限判断，失败文案由调用方用 toast 提示。
    @ViewBuilder
    private var saveToAlbumButton: some View {
        if let onSaveToAlbum {
            SecondaryButton(
                title: isSavingToAlbum ? "保存中…" : "保存到相册",
                systemImage: "square.and.arrow.down",
                tone: .neutral,
                size: .small,
                isEnabled: !isSavingToAlbum,
                isLoading: isSavingToAlbum,
                action: {
                    guard !isSavingToAlbum else { return }
                    isSavingToAlbum = true
                    Task { @MainActor in
                        await onSaveToAlbum()
                        isSavingToAlbum = false
                    }
                }
            )
        }
    }

    /// 动作条容器。
    private func actionRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: AppMetrics.tightGap) {
            content()
        }
        .padding(.horizontal, AppMetrics.cardPadding)
        .frame(minHeight: AppMetrics.resultActionHeight)
        .padding(.bottom, AppMetrics.blockGap)
    }
}

/// 自绘进度环（不用不确定样式的 ProgressView）。
struct ProgressRing: View {

    /// 0…0.9 的填充比例。
    var fraction: Double

    /// 直径。
    var size: CGFloat = AppMetrics.progressRingSize

    /// 旋转角度（无限缓慢旋转表示仍在工作）。
    @State private var rotation: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.separator, lineWidth: AppMetrics.hairline * 4)

            Circle()
                .trim(from: 0, to: max(min(fraction, 1), 0.02))
                .stroke(
                    Theme.accent,
                    style: StrokeStyle(
                        lineWidth: AppMetrics.hairline * 4,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90 + rotation))

            Text("\(Int((max(min(fraction, 0.9), 0)) * 100))%")
                .font(AppFont.caption)
                .foregroundColor(Theme.textSecondary)
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: AppMetrics.normal * 8).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
        .accessibilityLabel(Text("正在绘制图片"))
    }
}

#if DEBUG
struct AIResultCard_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: AppMetrics.blockGap) {
                AIResultCard(
                    feature: .polish,
                    state: .streaming("好的，我把这句话改得更"),
                    providerName: "DeepSeek",
                    onCancel: {}
                )
                AIResultCard(
                    feature: .translate,
                    state: .done("This is the translated text."),
                    providerName: "通义千问",
                    onCopy: {},
                    onRetry: {}
                )
                AIResultCard(
                    feature: .polish,
                    state: .failed(AIErrorViewData(title: "API Key 无效或已过期", suggestion: "请到设置里重新填写 API Key。")),
                    providerName: "DeepSeek",
                    onRetry: {}
                )
                AIResultCard(
                    feature: .image,
                    state: .imageGenerating(ImageProgress(prompt: "一只在雪地里的柴犬", stage: .drawing)),
                    providerName: "通义万相",
                    onCancel: {}
                )
            }
            .padding(AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground)
    }
}
#endif
