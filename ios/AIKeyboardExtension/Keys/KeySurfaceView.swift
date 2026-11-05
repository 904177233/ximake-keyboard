//
//  KeySurfaceView.swift
//  墨语键盘 · 键区
//
//  整个键区是一个视图：自己画所有键，自己处理所有触摸。
//
//  为什么不用一堆按钮：
//  - 按钮之间的缝隙是死区，打字时手指落在缝里就丢字。这里用最近的键接住每一次触摸。
//  - 按钮要等抬手才响应，第二根手指按下时第一个键可能还没出字。这里第二根手指一落下，
//    第一个键立刻上屏，两个拇指交替快打不吞字、不乱序。
//  - 上滑打数字、空格滑动移光标、退格连删都要拿到完整的触摸过程。
//

import UIKit

/// 键区事件接收方。
@MainActor
protocol KeySurfaceDelegate: AnyObject {
    /// 键被按下或抬起时触发一个动作。
    func keySurface(_ surface: KeySurfaceView, didTrigger action: KeyAction)
    /// 空格键滑动移动光标。
    func keySurface(_ surface: KeySurfaceView, moveCursorBy offset: Int)
    /// 退格键左滑清空组字。
    func keySurfaceDidSwipeClear(_ surface: KeySurfaceView)
    /// 按键触感与按键音。
    func keySurfaceDidPress(_ surface: KeySurfaceView, action: KeyAction)
    /// 长按空格：开始说话。
    func keySurfaceDidBeginSpaceHold(_ surface: KeySurfaceView)
    /// 按着空格往上滑：要取消（true）或回到正常（false）。
    func keySurface(_ surface: KeySurfaceView, spaceHoldWillCancel cancel: Bool)
    /// 松开空格：说完了，或者取消。
    func keySurfaceDidEndSpaceHold(_ surface: KeySurfaceView, cancelled: Bool)
}

final class KeySurfaceView: UIView, UIInputViewAudioFeedback {

    weak var delegate: KeySurfaceDelegate?

    /// 九宫格左栏。
    let sideStrip = T9SideStrip()

    var enableInputClicksWhenVisible: Bool { true }

    private(set) var keys: [KeyDef] = []
    private var palette = MoyuPalette(theme: .ink, dark: false)
    private var mascot: UIImage?
    private var cornerRadius: CGFloat = 9
    private var imageCache: [String: UIImage] = [:]

    /// 正在按着的键。
    private final class Press {
        var keyIndex: Int
        let startPoint: CGPoint
        var isAlternate = false
        var didLongPress = false
        var didFire = false
        var cursorMode = false
        var cursorSteps = 0
        /// 长按空格在说话。
        var voiceHold = false
        var holdCancel = false
        var holdTask: Task<Void, Never>?

        init(keyIndex: Int, startPoint: CGPoint) {
            self.keyIndex = keyIndex
            self.startPoint = startPoint
        }
    }

    private var presses: [ObjectIdentifier: Press] = [:]
    private let popup = KeyPopupView()
    /// 正在滑空格移光标：键面变暗，提示左右滑。
    private var cursorActive = false {
        didSet {
            if oldValue != cursorActive { setNeedsDisplay() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        addSubview(sideStrip)
        sideStrip.isHidden = true
        popup.isHidden = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// 气泡要盖到候选栏上面，所以挂在外层视图上。
    func installPopup(in container: UIView) {
        if popup.superview !== container {
            container.addSubview(popup)
        }
    }

    /// 更新键位和外观。
    func configure(layout: KeyboardLayoutResult, palette: MoyuPalette, mascot: UIImage?) {
        // 键的数量变了说明换了页，正按着的键已经没有意义
        if layout.keys.count != keys.count {
            cancelAllPresses()
        }
        self.keys = layout.keys
        self.palette = palette
        self.mascot = mascot
        imageCache.removeAll()
        popup.apply(palette: palette)
        if let strip = layout.sideStrip {
            sideStrip.frame = strip
            sideStrip.isHidden = false
            sideStrip.apply(palette: palette)
        } else {
            sideStrip.isHidden = true
        }
        rebuildAccessibility()
        setNeedsDisplay()
    }

    private func cancelAllPresses() {
        for press in presses.values {
            press.holdTask?.cancel()
        }
        presses.removeAll()
        popup.isHidden = true
    }

    private func rebuildAccessibility() {
        isAccessibilityElement = false
        accessibilityElements = keys.map { key -> UIAccessibilityElement in
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = Self.accessibilityLabel(for: key)
            element.accessibilityTraits = .keyboardKey
            element.accessibilityFrameInContainerSpace = key.frame
            return element
        }
    }

    private static func accessibilityLabel(for key: KeyDef) -> String {
        switch key.action {
        case .backspace: return "退格"
        case .shift: return "大写"
        case .space: return "空格"
        case .language: return "中英切换"
        case .showSymbols: return "表情和符号"
        case .nextKeyboard: return "下一个键盘"
        default: return key.title
        }
    }

    // MARK: - 绘制

    override func draw(_ rect: CGRect) {
        for (index, key) in keys.enumerated() where key.frame.intersects(rect.insetBy(dx: -2, dy: -2)) {
            drawKey(key, isPressed: isPressed(index))
        }
        if cursorActive {
            palette.canvas.withAlphaComponent(0.72).setFill()
            UIRectFillUsingBlendMode(bounds, .normal)
            drawCentered("◀   左右滑动移动光标   ▶", in: bounds,
                         font: .systemFont(ofSize: 15, weight: .medium), color: palette.secondary)
        }
    }

    private func isPressed(_ index: Int) -> Bool {
        presses.values.contains { $0.keyIndex == index && !$0.didFire }
    }

    private func drawKey(_ key: KeyDef, isPressed: Bool) {
        let path = UIBezierPath(roundedRect: key.frame, cornerRadius: cornerRadius)
        let fill: UIColor
        switch key.style {
        case .letter, .space:
            fill = isPressed ? palette.keyPressed : palette.key
        case .function:
            fill = isPressed ? palette.functionPressed : palette.function
        case .accent:
            fill = key.isDisabled ? palette.function : palette.accent
        }
        if key.style != .accent {
            palette.edge.setFill()
            UIBezierPath(roundedRect: key.frame.offsetBy(dx: 0, dy: 1), cornerRadius: cornerRadius).fill()
        }
        (isPressed && key.style == .accent ? fill.withAlphaComponent(0.82) : fill).setFill()
        path.fill()

        let textColor: UIColor
        switch key.style {
        case .accent:
            textColor = key.isDisabled ? palette.secondary : palette.onAccent
        case .space:
            textColor = palette.secondary
        default:
            textColor = key.isDisabled ? palette.secondary : palette.text
        }

        if let label = key.languageLabel {
            drawLanguage(label, in: key.frame)
        } else if let symbol = key.symbol {
            drawSymbol(symbol, in: key.frame, color: textColor, pointSize: 19)
        } else if let caption = key.caption {
            drawCaptioned(title: key.title, caption: caption, frame: key.frame, color: textColor, fontSize: key.fontSize)
        } else if !key.title.isEmpty {
            let weight: UIFont.Weight = key.style == .accent ? .semibold : .regular
            drawCentered(key.title, in: key.frame, font: .systemFont(ofSize: key.fontSize, weight: weight), color: textColor)
        }

        if let hint = key.hint {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10),
                .foregroundColor: palette.secondary
            ]
            let size = (hint as NSString).size(withAttributes: attributes)
            (hint as NSString).draw(at: CGPoint(x: key.frame.maxX - size.width - 3.5, y: key.frame.minY + 1.5),
                                    withAttributes: attributes)
        }

        if key.style == .space, key.frame.width > 80 {
            drawMascot(in: key.frame)
        }
    }

    private func drawCentered(_ text: String, in frame: CGRect, font: UIFont, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
                                withAttributes: attributes)
    }

    private func drawCaptioned(title: String, caption: String, frame: CGRect, color: UIColor, fontSize: CGFloat) {
        let captionFont = UIFont.systemFont(ofSize: 10)
        let titleFont = UIFont.systemFont(ofSize: fontSize)
        let captionAttributes: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: palette.secondary]
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: color, .kern: 0.6]
        let captionSize = (caption as NSString).size(withAttributes: captionAttributes)
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let total = captionSize.height + titleSize.height - 3
        var y = frame.midY - total / 2
        (caption as NSString).draw(at: CGPoint(x: frame.midX - captionSize.width / 2, y: y), withAttributes: captionAttributes)
        y += captionSize.height - 3
        (title as NSString).draw(at: CGPoint(x: frame.midX - titleSize.width / 2, y: y), withAttributes: titleAttributes)
    }

    private func drawLanguage(_ label: (active: String, inactive: String, activeFirst: Bool), in frame: CGRect) {
        let active = NSAttributedString(string: label.active, attributes: [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: palette.text
        ])
        let inactive = NSAttributedString(string: label.inactive, attributes: [
            .font: UIFont.systemFont(ofSize: 11), .foregroundColor: palette.secondary
        ])
        let joined = NSMutableAttributedString()
        joined.append(label.activeFirst ? active : inactive)
        joined.append(label.activeFirst ? inactive : active)
        let size = joined.size()
        joined.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }

    private func symbolImage(_ name: String, color: UIColor, pointSize: CGFloat) -> UIImage? {
        let cacheKey = "\(name)|\(pointSize)|\(color.hashValue)"
        if let cached = imageCache[cacheKey] {
            return cached
        }
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let image = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        if let image {
            imageCache[cacheKey] = image
        }
        return image
    }

    private func drawSymbol(_ name: String, in frame: CGRect, color: UIColor, pointSize: CGFloat) {
        guard let image = symbolImage(name, color: color, pointSize: pointSize) else { return }
        image.draw(at: CGPoint(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2))
    }

    private func drawMascot(in frame: CGRect) {
        guard let mascot else { return }
        let side: CGFloat = 20
        let target = CGRect(x: frame.maxX - side - 9, y: frame.midY - side / 2, width: side, height: side)
        let drawable = mascot.isSymbolImage ? mascot.withTintColor(palette.accent, renderingMode: .alwaysOriginal) : mascot
        let scale = min(side / max(drawable.size.width, 1), side / max(drawable.size.height, 1))
        let size = CGSize(width: drawable.size.width * scale, height: drawable.size.height * scale)
        drawable.draw(in: CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2,
                                 width: size.width, height: size.height))
    }

    // MARK: - 找键

    /// 离手指最近的键。手指落在缝里也能接住。
    private func keyIndex(at point: CGPoint) -> Int? {
        var best: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, key) in keys.enumerated() {
            if key.frame.contains(point) {
                return index
            }
            let dx = max(key.frame.minX - point.x, 0, point.x - key.frame.maxX)
            let dy = max(key.frame.minY - point.y, 0, point.y - key.frame.maxY)
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func redraw(keyIndex index: Int) {
        guard keys.indices.contains(index) else { return }
        setNeedsDisplay(keys[index].frame.insetBy(dx: -2, dy: -2))
    }

    // MARK: - 触摸

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 新手指落下：之前按着的字符键马上出字，保证两个拇指交替时顺序正确。
        for press in presses.values where !press.didFire && !press.cursorMode && keys.indices.contains(press.keyIndex) {
            let key = keys[press.keyIndex]
            if isCharacterKey(key) {
                fire(press, key: key)
                redraw(keyIndex: press.keyIndex)
            }
        }
        for touch in touches {
            let point = touch.location(in: self)
            guard let index = keyIndex(at: point) else { continue }
            let press = Press(keyIndex: index, startPoint: point)
            presses[ObjectIdentifier(touch)] = press
            begin(press)
        }
    }

    private func isCharacterKey(_ key: KeyDef) -> Bool {
        switch key.action {
        case .letter, .t9, .text, .punctuation, .separator:
            return true
        default:
            return false
        }
    }

    private func begin(_ press: Press) {
        let key = keys[press.keyIndex]
        delegate?.keySurfaceDidPress(self, action: key.action)
        redraw(keyIndex: press.keyIndex)
        if key.showsPopup {
            showPopup(for: key, alternate: false)
        }

        switch key.action {
        case .backspace:
            // 退格按下就删，按住连删，越按越快
            delegate?.keySurface(self, didTrigger: .backspace)
            press.didFire = false
            press.holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 420_000_000)
                var repeats = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    press.didLongPress = true
                    self.delegate?.keySurface(self, didTrigger: .backspace)
                    repeats += 1
                    try? await Task.sleep(nanoseconds: repeats > 20 ? 40_000_000 : 75_000_000)
                }
            }
        case .shift:
            delegate?.keySurface(self, didTrigger: .shift)
            press.didFire = true
        case .enter:
            // 长按回车：只换行，不发送。微信这类 App 收到 "\n" 就发送，"\r\n" 不等于它，就只是换行
            press.holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, let self, !press.didFire else { return }
                press.didLongPress = true
                press.didFire = true
                self.delegate?.keySurface(self, didTrigger: .text("\r\n"))
                self.showPopupText("换行", over: key)
                self.redraw(keyIndex: press.keyIndex)
            }
        case .space:
            // 按住不动 0.45 秒：说话。先滑动就是移光标，不会触发
            press.holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, let self, !press.cursorMode, !press.didFire else { return }
                press.didLongPress = true
                press.voiceHold = true
                self.popup.isHidden = true
                self.delegate?.keySurfaceDidBeginSpaceHold(self)
            }
        default:
            if key.alternate != nil {
                press.holdTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 380_000_000)
                    guard !Task.isCancelled, let self else { return }
                    press.didLongPress = true
                    press.isAlternate = true
                    if self.keys.indices.contains(press.keyIndex) {
                        self.showPopup(for: self.keys[press.keyIndex], alternate: true)
                    }
                }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let press = presses[ObjectIdentifier(touch)], !press.didFire,
                  keys.indices.contains(press.keyIndex) else { continue }
            let point = touch.location(in: self)
            let dx = point.x - press.startPoint.x
            let dy = point.y - press.startPoint.y
            let key = keys[press.keyIndex]

            switch key.action {
            case .space:
                if press.voiceHold {
                    let cancel = dy < -50
                    if cancel != press.holdCancel {
                        press.holdCancel = cancel
                        delegate?.keySurface(self, spaceHoldWillCancel: cancel)
                    }
                } else if press.cursorMode || abs(dx) > 10 {
                    if !press.cursorMode {
                        press.cursorMode = true
                        press.holdTask?.cancel()
                        cursorActive = true
                    }
                    let steps = Int(dx / 8)
                    if steps != press.cursorSteps {
                        delegate?.keySurface(self, moveCursorBy: steps - press.cursorSteps)
                        press.cursorSteps = steps
                    }
                }
            case .backspace:
                if dx < -46, !press.didLongPress {
                    press.holdTask?.cancel()
                    press.didFire = true
                    delegate?.keySurfaceDidSwipeClear(self)
                    redraw(keyIndex: press.keyIndex)
                }
            default:
                if key.alternate != nil {
                    if dy < -16, !press.isAlternate {
                        press.isAlternate = true
                        showPopup(for: key, alternate: true)
                    } else if dy > -8, press.isAlternate, !press.didLongPress {
                        press.isAlternate = false
                        showPopup(for: key, alternate: false)
                    }
                }
                // 手指滑到别的键上：换键，和系统键盘一样
                if !press.isAlternate, !key.frame.insetBy(dx: -6, dy: -8).contains(point),
                   let index = keyIndex(at: point), index != press.keyIndex {
                    press.holdTask?.cancel()
                    redraw(keyIndex: press.keyIndex)
                    press.keyIndex = index
                    redraw(keyIndex: index)
                    if keys[index].showsPopup {
                        showPopup(for: keys[index], alternate: false)
                    } else {
                        popup.isHidden = true
                    }
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            guard let press = presses[identifier] else { continue }
            presses[identifier] = nil
            press.holdTask?.cancel()
            let index = press.keyIndex
            guard keys.indices.contains(index) else { continue }
            let key = keys[index]
            redraw(keyIndex: index)
            if press.voiceHold {
                delegate?.keySurfaceDidEndSpaceHold(self, cancelled: press.holdCancel)
                continue
            }
            if press.didFire || press.cursorMode || key.action == .backspace || key.action == .shift {
                continue
            }
            fire(press, key: key)
        }
        updateCursorActive()
        hidePopupIfIdle()
    }

    private func updateCursorActive() {
        cursorActive = presses.values.contains { $0.cursorMode }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            guard let press = presses[identifier] else { continue }
            presses[identifier] = nil
            press.holdTask?.cancel()
            redraw(keyIndex: press.keyIndex)
            if press.voiceHold {
                delegate?.keySurfaceDidEndSpaceHold(self, cancelled: true)
            }
        }
        updateCursorActive()
        hidePopupIfIdle()
    }

    private func fire(_ press: Press, key: KeyDef) {
        press.didFire = true
        press.holdTask?.cancel()
        popup.isHidden = true
        if key.isDisabled { return }
        if press.isAlternate, let alternate = key.alternate {
            delegate?.keySurface(self, didTrigger: alternate)
        } else {
            delegate?.keySurface(self, didTrigger: key.action)
        }
    }

    private func hidePopupIfIdle() {
        if presses.isEmpty {
            popup.isHidden = true
        }
    }

    private func showPopupText(_ text: String, over key: KeyDef) {
        guard let container = popup.superview else { return }
        popup.show(text: text, above: convert(key.frame, to: container), within: container.bounds)
    }

    private func showPopup(for key: KeyDef, alternate: Bool) {
        guard let container = popup.superview else { return }
        let text = alternate ? (key.hint ?? key.title) : key.title
        let frame = convert(key.frame, to: container)
        popup.show(text: text, above: frame, within: container.bounds)
    }
}

/// 按键气泡。
final class KeyPopupView: UILabel {

    private var edgeInset: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        textAlignment = .center
        font = .systemFont(ofSize: 30)
        layer.cornerRadius = 11
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func apply(palette: MoyuPalette) {
        layer.backgroundColor = palette.key.cgColor
        textColor = palette.text
    }

    func show(text: String, above keyFrame: CGRect, within bounds: CGRect) {
        self.text = text
        let width = max(keyFrame.width + 14, 50)
        let height: CGFloat = 56
        var x = keyFrame.midX - width / 2
        x = min(max(x, edgeInset), bounds.width - width - edgeInset)
        let y = max(keyFrame.minY - height + 2, 0)
        frame = CGRect(x: x, y: y, width: width, height: height)
        isHidden = false
        superview?.bringSubviewToFront(self)
    }
}

/// 九宫格左栏：没在打字时是常用标点，打字时是拼音选项。
final class T9SideStrip: UIScrollView {

    /// 点了第几项。
    var onSelect: ((Int) -> Void)?

    private var labels: [UILabel] = []
    private var separators: [UIView] = []
    private var palette = MoyuPalette(theme: .ink, dark: false)
    private let rowHeight: CGFloat = 37.5
    private var count = 0
    private var currentItems: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 9
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func apply(palette: MoyuPalette) {
        self.palette = palette
        backgroundColor = palette.function
        currentItems = []
    }

    /// 更新内容。
    func update(items: [String], highlightFirst: Bool) {
        guard items != currentItems else { return }
        currentItems = items
        count = items.count
        while labels.count < items.count {
            let label = UILabel()
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            addSubview(label)
            labels.append(label)
            let separator = UIView()
            addSubview(separator)
            separators.append(separator)
        }
        for (index, label) in labels.enumerated() {
            let isVisible = index < items.count
            label.isHidden = !isVisible
            separators[index].isHidden = !isVisible
            guard isVisible else { continue }
            label.text = items[index]
            let isFirst = highlightFirst && index == 0
            label.font = .systemFont(ofSize: 15, weight: isFirst ? .semibold : .regular)
            label.textColor = isFirst ? palette.accentText : palette.text
            separators[index].backgroundColor = palette.line
        }
        setNeedsLayout()
        contentOffset = .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        for index in 0..<min(count, labels.count) {
            labels[index].frame = CGRect(x: 2, y: CGFloat(index) * rowHeight, width: width - 4, height: rowHeight)
            separators[index].frame = CGRect(x: 0, y: CGFloat(index + 1) * rowHeight - 0.5, width: width, height: 0.5)
        }
        contentSize = CGSize(width: width, height: CGFloat(count) * rowHeight)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let index = Int(gesture.location(in: self).y / rowHeight)
        if index >= 0, index < count {
            onSelect?(index)
        }
    }
}
