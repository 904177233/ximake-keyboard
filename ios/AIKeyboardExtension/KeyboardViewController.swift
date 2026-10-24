//
//  KeyboardViewController.swift
//  墨语（Moyu）键盘扩展 · 宿主容器
//
//  模块职责：键盘扩展的唯一入口（`NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).KeyboardViewController`）。
//            负责：①装载 SwiftUI 根视图；②管理 `inputView` 的动态高度（竖屏 258 / 横屏 200 /
//            AI 面板 +168 / 结果页 +180 / 设置 +168）；③跟随宿主键盘外观（浅色 / 深色）；
//            ④把 `textDocumentProxy` 与系统回调注入 `KeyboardViewModel`。
//  设计依据：docs/02 §4.7（键盘扩展契约）、design/键盘布局规范.md §1（总高）、§6（动效）、§7（安全区）。
//  兼容性：iOS 16.0+。`requestInputViewHeightUpdate()` 在 iOS 16 不是公开 API，
//          因此统一走「高度约束 + layoutIfNeeded」的兼容路径，见 `applyHeight(animated:)`。
//

import Combine
import SwiftUI
import UIKit

/// 墨语键盘扩展主控制器。
///
/// 生命周期：
/// 1. `viewDidLoad` 搭建 SwiftUI 宿主、装配约束、注入代理与回调；
/// 2. `viewWillLayoutSubviews` 依据「横竖屏 + 当前页面」计算目标高度并平滑更新；
/// 3. `textDidChange` 刷新代理（宿主切换输入框时 `textDocumentProxy` 会变化）。
final class KeyboardViewController: UIInputViewController {

    // MARK: - 常量

    /// 高度更新时使用的选择器名（仅用于向系统请求重新测量；iOS 16 上通常不存在）。
    private static let heightUpdateSelectorName = "requestInputViewHeightUpdate"

    /// 收起键盘面板时的弹簧阻尼（design/键盘布局规范.md §6：收起用 0.9）。
    private static let collapseDampingRatio: CGFloat = 0.9

    // MARK: - 子视图与状态

    /// 键盘状态机（整个扩展唯一实例）。
    private let model = KeyboardViewModel()

    /// SwiftUI 宿主控制器（懒加载，全生命周期复用）。
    private var hostingController: UIHostingController<KeyboardRootView>?

    /// `view` 的高度约束（唯一的高度来源）。`UIInputViewController` 以 `view` 作为输入视图，
    /// 因此在 `view` 上加高度约束即等于控制键盘高度。
    private var heightConstraint: NSLayoutConstraint?

    /// 正在运行的高度动画（快速连点时先停掉上一个，避免高度抖动）。
    private var heightAnimator: UIViewPropertyAnimator?

    /// 当前已应用的高度（避免重复动画）。
    private var appliedHeight: CGFloat = 0

    /// 上一次布局时的横屏状态（检测横竖屏翻转）。
    private var lastLandscape: Bool = false

    /// 观察状态变化的订阅（页面切换时刷新高度）。
    private var pageCancellable: AnyCancellable?

    /// 上一次的键盘外观（检测外观切换）。
    private var lastKeyboardAppearance: UIKeyboardAppearance = .default

    // MARK: - 输入视图

    // 说明：不为 `inputView` 提供覆写。`UIInputViewController` 以自身的 `view` 作为键盘输入视图
    //（`inputView` 类型为 `UIInputView?`），SwiftUI 宿主已作为子视图铺满 `view`，
    // 再覆写 `inputView` 会造成同一份视图被系统重复挂载。

    // MARK: - 生命周期

    /// 视图加载：搭建宿主、约束、代理注入。
    override func viewDidLoad() {
        super.viewDidLoad()

        // 键盘自身背景透明：真正的背景色由 SwiftUI 的 KeyboardShell 绘制，
        // 这样在「面板展开 / 收起」动画过程中不会出现白边。
        view.backgroundColor = .clear
        view.clipsToBounds = true

        setupHostingController()
        setupHeightConstraint()
        bindModel()

        model.activate()
        model.proxy = textDocumentProxy
        lastKeyboardAppearance = textDocumentProxy.keyboardAppearance ?? .default
        applyAppearance(lastKeyboardAppearance)
        applyHeight(animated: false)
    }

    /// 视图即将出现：刷新代理与完全访问状态。
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.proxy = textDocumentProxy
        model.refreshAccessState(hasFullAccess: hasFullAccess)
        applyHeight(animated: false)
    }

    /// 视图即将消失：取消 AI 请求、释放缩略图，压低扩展内存峰值。
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.deactivate()
    }

    /// 每次布局：同步横竖屏状态并刷新高度（高度只在这里与状态回调处更新）。
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()

        // 键盘自下而上出现时，宿主可能给 `view` 一个临时高度；约束必须始终等于目标值。
        ensureHeightConstraintAttached()

        model.proxy = textDocumentProxy
        model.setLandscape(isLandscapeLayout)
        applyHeight(animated: false)
    }

    /// 宿主输入框内容变化（切换输入框 / 外部插入）时刷新代理。
    /// - Parameter textInput: 触发变化的输入对象。
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.proxy = textDocumentProxy
        model.reloadContextPreview()
    }

    /// 外观（浅色 / 深色）变化时同步 SwiftUI 宿主。
    /// - Parameters:
    ///   - previousTraitCollection: 变化前的特征集合。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyAppearance(textDocumentProxy.keyboardAppearance ?? .default)
        }
    }

    /// 完全访问权限变化（设置里开关后回到键盘）时刷新 AI 可用性。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        model.refreshAccessState(hasFullAccess: hasFullAccess)
        model.proxy = textDocumentProxy
        refreshAppearanceIfNeeded()
    }

    // MARK: - 搭建

    /// 创建并挂载 SwiftUI 宿主控制器。
    private func setupHostingController() {
        let root = KeyboardRootView(model: model)
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(controller)
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
        hostingController = controller
    }

    /// 安装高度约束（挂在 `view` 上，保证成为输入视图时也生效）。
    private func setupHeightConstraint() {
        guard heightConstraint == nil else { return }
        let target = view.heightAnchor.constraint(equalToConstant: currentTargetHeight)
        target.priority = .required
        target.isActive = true
        heightConstraint = target
        appliedHeight = target.constant
    }

    /// 若高度约束在布局过程中被系统移除（键盘重建），重新挂上。
    private func ensureHeightConstraintAttached() {
        guard let constraint = heightConstraint else {
            setupHeightConstraint()
            return
        }
        if constraint.isActive == false {
            constraint.isActive = true
        }
    }

    /// 绑定状态机回调与页面变化。
    private func bindModel() {
        model.onGlobe = { [weak self] in
            guard let self else { return }
            self.advanceToNextInputMode()
        }
        model.onDismissKeyboard = { [weak self] in
            guard let self else { return }
            self.advanceToNextInputMode()
        }
        model.onHeightChangeNeeded = { [weak self] in
            guard let self else { return }
            self.applyHeight(animated: true)
        }

        pageCancellable = model.$page
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyHeight(animated: true)
            }
    }

    // MARK: - 高度

    /// 当前是否为横屏布局（iPhone 横屏 verticalSizeClass 为 compact；iPad 恒为 regular）。
    private var isLandscapeLayout: Bool {
        traitCollection.verticalSizeClass == .compact
    }

    /// 依据「横竖屏 + 页面 + 安全区」计算目标高度。
    private var currentTargetHeight: CGFloat {
        KMLayout.keyboardHeight(
            isLandscape: isLandscapeLayout,
            page: model.page,
            safeAreaBottom: isLandscapeLayout ? 0 : view.safeAreaInsets.bottom
        )
    }

    /// 应用目标高度（唯一改高度的地方）。
    ///
    /// 兼容方案说明：iOS 16 没有公开的 `requestInputViewHeightUpdate()`，
    /// 因此这里直接改 `heightAnchor` 常量并 `layoutIfNeeded()`，让宿主重新测量；
    /// 若未来系统提供该方法则通过 `responds(to:)` 转发，不产生编译期依赖。
    /// - Parameter animated: 是否使用弹簧动画（页面切换为 true，旋转/首次布局为 false）。
    private func applyHeight(animated: Bool) {
        let target = currentTargetHeight
        let changed = abs(target - appliedHeight) > 0.5

        if let constraint = heightConstraint {
            if abs(constraint.constant - target) > 0.5 {
                constraint.constant = target
            }
        } else {
            setupHeightConstraint()
        }

        if animated && changed && !UIAccessibility.isReduceMotionEnabled {
            // 展开用 0.35s / 0.82 阻尼；收起用 0.28s / 0.9 阻尼（design/键盘布局规范.md §6）。
            let expanding = target > appliedHeight
            let duration: TimeInterval = expanding ? Theme.Motion.expandDuration : Theme.Motion.collapseDuration
            let damping: CGFloat = expanding ? CGFloat(Theme.Motion.springDamping) : Self.collapseDampingRatio
            heightAnimator?.stopAnimation(true)
            let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: damping) { [weak self] in
                self?.view.layoutIfNeeded()
            }
            heightAnimator = animator
            animator.startAnimation()
        } else {
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }

        if changed {
            appliedHeight = target
            lastLandscape = isLandscapeLayout
            requestHeightUpdateFromSystem()
        }
    }

    /// 向系统请求重新测量键盘高度。
    ///
    /// iOS 16 上该方法通常不存在，此时退回「约束 + 布局」路径（`applyHeight` 已完成），
    /// 只是额外通知一下宿主，失败无副作用。
    private func requestHeightUpdateFromSystem() {
        let selector = NSSelectorFromString(Self.heightUpdateSelectorName)
        if responds(to: selector) {
            perform(selector)
        }
        // 通知系统重新测量：`view` 就是本控制器的输入视图（`UIInputViewController` 以 `view` 作为 inputView）。
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    // MARK: - 外观

    /// 按宿主键盘外观切换 SwiftUI 宿主的用户界面风格。
    /// - Parameter appearance: 宿主键盘外观（.light / .dark / .default）。
    private func applyAppearance(_ appearance: UIKeyboardAppearance) {
        guard let controller = hostingController else { return }
        switch appearance {
        case .dark:
            controller.overrideUserInterfaceStyle = .dark
        case .light:
            controller.overrideUserInterfaceStyle = .light
        default:
            controller.overrideUserInterfaceStyle = .unspecified
        }
        lastKeyboardAppearance = appearance
    }

    /// 外观变化时（宿主切换输入框可能改变 `keyboardAppearance`）刷新。
    private func refreshAppearanceIfNeeded() {
        let appearance = textDocumentProxy.keyboardAppearance ?? .default
        guard appearance != lastKeyboardAppearance else { return }
        applyAppearance(appearance)
    }
}
