//
//  TopBarView.swift
//  墨语键盘 · 顶栏
//
//  同一块地方按状态换内容：
//    空闲   一排圆形工具图标 + 右边的 AI 圆钮
//    打字   小字拼音 + 候选 + 右边的展开箭头
//    上屏后 工具入口 + 联想词 + AI 圆钮
//

import UIKit

/// 工具栏按钮。
enum ToolID: String, CaseIterable {
    case polish, translate, reply, expand, image, voice, symbols, clipboard, phrases, layout, settings

    var symbol: String {
        switch self {
        case .polish: return "wand.and.stars"
        case .translate: return "character.bubble"
        case .reply: return "bubble.left.and.bubble.right"
        case .expand: return "text.append"
        case .image: return "photo"
        case .voice: return "mic"
        case .symbols: return "face.smiling"
        case .clipboard: return "doc.on.clipboard"
        case .phrases: return "text.quote"
        case .layout: return "keyboard"
        case .settings: return "gearshape"
        }
    }

    var label: String {
        switch self {
        case .polish: return "润色"
        case .translate: return "翻译"
        case .reply: return "回复"
        case .expand: return "扩写"
        case .image: return "画图"
        case .voice: return "语音"
        case .symbols: return "表情和符号"
        case .clipboard: return "剪贴板"
        case .phrases: return "常用短语"
        case .layout: return "换键盘布局"
        case .settings: return "设置"
        }
    }
}

/// 顶栏内容。
enum TopBarContent: Equatable {
    case tools
    case composing(selected: String, spelling: String, candidates: [String], rawIndex: Int?)
    case suggestions(words: [String], aiWords: [String])
    case hint(String)
}

final class TopBarView: UIView {

    var onTool: ((ToolID) -> Void)?
    var onKnob: (() -> Void)?
    var onCandidate: ((Int) -> Void)?
    var onExpand: (() -> Void)?
    var onShowTools: (() -> Void)?
    var onSuggestion: ((Int) -> Void)?

    private let toolsScroll = UIScrollView()
    private var toolButtons: [ToolID: UIButton] = [:]
    private var visibleTools: [ToolID] = []
    private let knob = UIButton(type: .custom)
    private let expandButton = UIButton(type: .custom)
    private let expandDivider = UIView()
    private let gridButton = UIButton(type: .custom)
    private let preedit = UILabel()
    private let strip = CandidateStripView()
    private let hintLabel = UILabel()
    private var palette = MoyuPalette(theme: .ink, dark: false)
    private var content: TopBarContent = .tools

    override init(frame: CGRect) {
        super.init(frame: frame)
        toolsScroll.showsHorizontalScrollIndicator = false
        toolsScroll.alwaysBounceHorizontal = false
        addSubview(toolsScroll)

        knob.setImage(Self.symbol("drop.fill", size: 17), for: .normal)
        knob.accessibilityLabel = "AI 对话"
        knob.addAction(UIAction { [weak self] _ in self?.onKnob?() }, for: .touchUpInside)
        addSubview(knob)

        expandButton.setImage(Self.symbol("chevron.down", size: 13), for: .normal)
        expandButton.accessibilityLabel = "展开候选"
        expandButton.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .touchUpInside)
        addSubview(expandButton)
        addSubview(expandDivider)

        gridButton.setImage(Self.symbol("square.grid.3x3", size: 15), for: .normal)
        gridButton.accessibilityLabel = "工具"
        gridButton.addAction(UIAction { [weak self] _ in self?.onShowTools?() }, for: .touchUpInside)
        addSubview(gridButton)

        preedit.font = .systemFont(ofSize: 12)
        preedit.lineBreakMode = .byTruncatingHead
        addSubview(preedit)

        strip.onSelect = { [weak self] index in
            guard let self else { return }
            if case .composing = self.content {
                self.onCandidate?(index)
            } else {
                self.onSuggestion?(index)
            }
        }
        addSubview(strip)

        hintLabel.font = .systemFont(ofSize: 12)
        addSubview(hintLabel)
        apply(content: .tools)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private static func symbol(_ name: String, size: CGFloat) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }

    /// 设置可见的工具按钮。
    func setTools(_ tools: [ToolID]) {
        guard tools != visibleTools else { return }
        visibleTools = tools
        toolButtons.values.forEach { $0.removeFromSuperview() }
        toolButtons = [:]
        for tool in tools {
            let button = UIButton(type: .custom)
            button.setImage(Self.symbol(tool.symbol, size: 16), for: .normal)
            button.accessibilityLabel = tool.label
            button.addAction(UIAction { [weak self] _ in self?.onTool?(tool) }, for: .touchUpInside)
            toolsScroll.addSubview(button)
            toolButtons[tool] = button
        }
        applyColors()
        setNeedsLayout()
    }

    /// 更新配色。
    func apply(palette: MoyuPalette) {
        self.palette = palette
        applyColors()
        strip.apply(palette: palette)
    }

    private func applyColors() {
        for button in toolButtons.values {
            button.backgroundColor = palette.key
            button.tintColor = palette.text
        }
        knob.backgroundColor = palette.accent
        knob.tintColor = palette.onAccent
        expandButton.tintColor = palette.secondary
        expandDivider.backgroundColor = palette.line
        gridButton.backgroundColor = palette.key
        gridButton.tintColor = palette.text
        preedit.textColor = palette.secondary
        hintLabel.textColor = palette.secondary
    }

    /// 更新内容。
    func apply(content: TopBarContent) {
        let changed = content != self.content
        self.content = content
        var showsTools = false
        var showsKnob = false
        var showsExpand = false
        var showsGrid = false
        var showsPreedit = false
        var showsStrip = false
        var showsHint = false

        switch content {
        case .tools:
            showsTools = true
            showsKnob = true
        case let .composing(selected, spelling, candidates, rawIndex):
            showsExpand = true
            showsPreedit = true
            showsStrip = true
            let text = NSMutableAttributedString()
            if !selected.isEmpty {
                text.append(NSAttributedString(string: selected + " ", attributes: [
                    .foregroundColor: palette.text,
                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold)
                ]))
            }
            text.append(NSAttributedString(string: spelling, attributes: [
                .foregroundColor: palette.secondary,
                .font: UIFont.systemFont(ofSize: 12),
                .kern: 0.2
            ]))
            preedit.attributedText = text
            if changed {
                layoutStrip(for: content)
                strip.update(items: candidates.map { .init(text: $0, style: .candidate) },
                             markFirst: true, rawIndex: rawIndex)
            }
        case let .suggestions(words, aiWords):
            showsKnob = true
            showsGrid = true
            showsStrip = true
            if changed {
                layoutStrip(for: content)
                let items = aiWords.map { CandidateStripView.Item(text: $0, style: .pill) }
                    + words.map { CandidateStripView.Item(text: $0, style: .plain) }
                strip.update(items: items, markFirst: false, rawIndex: nil)
            }
        case let .hint(text):
            hintLabel.text = text
            showsHint = true
        }

        toolsScroll.isHidden = !showsTools
        knob.isHidden = !showsKnob
        expandButton.isHidden = !showsExpand
        expandDivider.isHidden = !showsExpand
        gridButton.isHidden = !showsGrid
        preedit.isHidden = !showsPreedit
        strip.isHidden = !showsStrip
        hintLabel.isHidden = !showsHint
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        let knobSide = min(38, height - 8)
        knob.frame = CGRect(x: width - knobSide - 7, y: (height - knobSide) / 2, width: knobSide, height: knobSide)
        knob.layer.cornerRadius = knobSide / 2

        // 工具图标
        let circle = min(36, height - 10)
        let gap: CGFloat = 6
        toolsScroll.frame = CGRect(x: 0, y: 0, width: knob.frame.minX - 3, height: height)
        var x: CGFloat = 6
        for tool in visibleTools {
            guard let button = toolButtons[tool] else { continue }
            button.frame = CGRect(x: x, y: (height - circle) / 2, width: circle, height: circle)
            button.layer.cornerRadius = circle / 2
            x += circle + gap
        }
        toolsScroll.contentSize = CGSize(width: x, height: height)

        let expandWidth: CGFloat = 40
        expandButton.frame = CGRect(x: width - expandWidth, y: height - 36, width: expandWidth, height: 36)
        expandDivider.frame = CGRect(x: width - expandWidth, y: height - 30, width: 0.5, height: 24)

        gridButton.frame = CGRect(x: 6, y: (height - circle) / 2, width: circle, height: circle)
        gridButton.layer.cornerRadius = circle / 2

        preedit.frame = CGRect(x: 12, y: 3, width: width - 24, height: 14)
        layoutStrip(for: content)
        hintLabel.frame = bounds.insetBy(dx: 12, dy: 0)
    }

    /// 候选条的位置。更新内容前也要调，候选的高度依赖它。
    private func layoutStrip(for content: TopBarContent) {
        let width = bounds.width
        let height = bounds.height
        switch content {
        case .composing:
            strip.frame = CGRect(x: 0, y: 16, width: width - 40, height: height - 16)
        case .suggestions:
            let circle = min(36, height - 10)
            let left = 6 + circle + 2
            let knobSide = min(38, height - 8)
            strip.frame = CGRect(x: left, y: 0, width: width - knobSide - 7 - left - 2, height: height)
        default:
            break
        }
    }
}

/// 横向滚动的候选条。滑动就是滚动，点一下就是选词，和系统其它列表一样。
final class CandidateStripView: UIScrollView {

    struct Item {
        enum Style {
            case candidate, plain, pill
        }
        let text: String
        let style: Style
    }

    var onSelect: ((Int) -> Void)?

    private var labels: [UILabel] = []
    private var ranges: [ClosedRange<CGFloat>] = []
    private let underline = UIView()
    private var palette = MoyuPalette(theme: .ink, dark: false)

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        alwaysBounceHorizontal = true
        delaysContentTouches = false
        underline.layer.cornerRadius = 1.25
        addSubview(underline)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func apply(palette: MoyuPalette) {
        self.palette = palette
        underline.backgroundColor = palette.accent
    }

    /// 更新内容。
    /// - Parameters:
    ///   - items: 要显示的词。
    ///   - markFirst: 是否标出首选。
    ///   - rawIndex: 原文候选的下标，后面加「原样」小字。
    func update(items: [Item], markFirst: Bool, rawIndex: Int?) {
        ranges.removeAll(keepingCapacity: true)
        while labels.count < items.count {
            let label = UILabel()
            label.textAlignment = .center
            addSubview(label)
            labels.append(label)
        }
        let height = bounds.height > 0 ? bounds.height : 32
        var x: CGFloat = 4
        for (index, label) in labels.enumerated() {
            guard index < items.count else {
                label.isHidden = true
                continue
            }
            let item = items[index]
            label.isHidden = false
            let isFirst = markFirst && index == 0
            let font: UIFont
            switch item.style {
            case .candidate:
                font = .systemFont(ofSize: 18, weight: isFirst ? .semibold : .regular)
            case .plain:
                font = .systemFont(ofSize: 17)
            case .pill:
                font = .systemFont(ofSize: 14)
            }
            let color = isFirst ? palette.accentText : palette.text
            let attributed = NSMutableAttributedString(string: item.text, attributes: [.font: font, .foregroundColor: color])
            if index == rawIndex {
                attributed.append(NSAttributedString(string: " 原样", attributes: [
                    .font: UIFont.systemFont(ofSize: 10), .foregroundColor: palette.secondary
                ]))
            }
            label.attributedText = attributed
            let textWidth = ceil(attributed.size().width)
            let padding: CGFloat = item.style == .pill ? 11 : 9
            let width = textWidth + padding * 2
            if item.style == .pill {
                label.frame = CGRect(x: x, y: (height - 30) / 2, width: width, height: 30)
                label.backgroundColor = palette.key
                label.layer.cornerRadius = 15
                label.layer.masksToBounds = true
                ranges.append(x...(x + width))
                x += width + 6
            } else {
                label.frame = CGRect(x: x, y: 0, width: width, height: height)
                label.backgroundColor = .clear
                label.layer.cornerRadius = 0
                ranges.append(x...(x + width))
                x += width
            }
            if isFirst {
                underline.frame = CGRect(x: x - width + padding, y: height - 3.5, width: textWidth, height: 2.5)
            }
        }
        underline.isHidden = !(markFirst && !items.isEmpty)
        contentSize = CGSize(width: x + 4, height: height)
        contentOffset = .zero
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: self).x
        if let index = ranges.firstIndex(where: { $0.contains(x) }) {
            onSelect?(index)
        }
    }
}
