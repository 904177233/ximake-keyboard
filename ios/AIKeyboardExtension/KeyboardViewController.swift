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
import Foundation
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

    /// 正在执行 `applyHeight` 的重入锁。
    ///
    /// 必要性（真机崩溃修复）：`applyHeight` 内部会 `layoutIfNeeded()` 强制布局，
    /// 而布局会再次回调 `viewWillLayoutSubviews`，后者又调用 `applyHeight` →
    /// 无限递归 → 栈溢出（`EXC_BAD_ACCESS / Thread stack size exceeded`）。
    /// 该锁保证同一时刻只有一层 `applyHeight` 在跑，内层直接返回。
    private var isApplyingHeight: Bool = false

    /// 观察状态变化的订阅（页面切换时刷新高度）。
    private var pageCancellable: AnyCancellable?

    /// 上一次的键盘外观（检测外观切换）。
    private var lastKeyboardAppearance: UIKeyboardAppearance = .default

    // MARK: - 内存治理状态

    /// 已注册到 `KMMemoryGovernor` 的可释放资源 token。
    ///
    /// 只在 `viewDidLoad` 注册一次（注册项是长生命周期对象，重复注册会让同一个资源
    /// 在治理器里出现多条记录、被重复释放）。闭包内部统一 `[weak self]`，不会造成循环引用。
    /// 注意：`model` 是 `let` 存储属性，不能写 `[weak model]`（Swift 只允许 weak 捕获可变的 class 引用），
    /// 一律以 `[weak self]` 捕获控制器、再由控制器访问 `model`。
    private var memoryReclaimerTokens: [UUID] = []

    /// 内存采样是否已启动（避免 `viewWillAppear` 反复重建 Timer）。
    private var isMemoryMonitoring: Bool = false

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
        setupMemoryGovernor()

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
        // 键盘每次弹出都可能被系统重建/复用，这里兜底恢复采样（幂等）。
        startMemoryMonitoringIfNeeded()
    }

    /// 视图即将消失：取消 AI 请求、释放缩略图，压低扩展内存峰值。
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.deactivate()
        // 键盘收起后不再需要周期采样：停掉 Timer，避免后台空转（下次弹出会重新启动）。
        stopMemoryMonitoringIfNeeded()
    }

    /// 每次布局：同步横竖屏状态并刷新高度（高度只在这里与状态回调处更新）。
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()

        // 键盘自下而上出现时，宿主可能给 `view` 一个临时高度；约束必须始终等于目标值。
        ensureHeightConstraintAttached()

        model.proxy = textDocumentProxy
        model.setLandscape(isLandscapeLayout)
        // 注意：这里**只能同步约束常量**，绝不能调 `layoutIfNeeded()`。
        // 该方法是布局回调，在其中强制布局会再次回到这里 —— 真机上表现为
        // `applyHeight → layoutBelowIfNeeded → viewWillLayoutSubviews → applyHeight`
        // 的无限递归，最终栈溢出崩溃（EXC_BAD_ACCESS / Thread stack size exceeded）。
        syncHeightConstraintOnly()
    }

    /// 宿主输入框内容变化（切换输入框 / 外部插入）时刷新代理。
    /// - Parameter textInput: 触发变化的输入对象。
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.proxy = textDocumentProxy
        model.reloadContextPreview()
        // 切输入框时 returnKeyType 会变（聊天框=发送、搜索框=搜索），回车键要跟着变。
        model.refreshReturnKeyKind()
        // 上下文变化是 AI 联想的触发时机 B（design/04 §4.4）。
        model.scheduleSuggestions()
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
            // 收起键盘 = 放弃第一响应者，让宿主 App 自己降下键盘。
            //
            // v1.6 之前这里调的是 `advanceToNextInputMode()`，语义完全错误：
            // 那是「切换到下一个输入法」，用户点「收起」会被强制换到别的键盘
            // （docs/09 §4 第 5 条审计时记下的缺陷）。`dismissKeyboard()` 才是
            // `UIInputViewController` 提供的「收起」动作。
            self.dismissKeyboard()
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

    // MARK: - 内存治理

    /// 把键盘侧的资源登记到 `KMMemoryGovernor`，并注入「是否正在拼字」回调。
    ///
    /// 登记时机：只在 `viewDidLoad` 调一次。资源闭包必须**幂等**（治理器可能连续调用）。
    /// 三个资源的释放代价分级：
    /// - `image-cache`（cheap）：生图原图 / 缩略图 + HTTP 缓存，释放后不影响输入；
    /// - `clipboard-history`（costly）：清空本地剪贴板上屏列表，属用户可感知操作，放第二档；
    /// - `pinyin-engine`（last）：中文引擎重建 15–25ms，只在 `terminal` 档位才动。
    private func setupMemoryGovernor() {
        let governor = KMMemoryGovernor.shared

        // 注入「是否正在拼字」：正在拼字时推迟重度释放，避免引擎重建打断当前候选。
        // 控制器已释放时返回 `true`（保守：宁可少放，也不在无主状态下动别人资源）。
        governor.shouldDeferHeavyRelease = { [weak self] in
            guard let self = self else { return true }
            return !self.model.composing.isEmpty
        }

        // ① 图片缓存：释放生图原图与缩略图（单张原图可达数 MB）。
        //    `URLCache` 兜底清掉 Networking 层的 HTTP 响应缓存（不走 App Group）。
        memoryReclaimerTokens.append(
            governor.register(
                name: "image-cache",
                estimatedBytes: 8 * 1024 * 1024,
                stage: .cheap
            ) { [weak self] in
                Self.runOnMain {
                    self?.model.releaseImageBuffers()
                    URLCache.shared.removeAllCachedResponses()
                }
            }
        )

        // ② 剪贴板历史：只清**内存里的上屏列表**（`clipboardItems`）。
        //    刻意不调 `KMInputEngine.shared.clearClipboard()`——那会连用户持久化的
        //    剪贴板历史一起清掉（写入 SharedStore），属于数据丢失，不适合做内存回收。
        memoryReclaimerTokens.append(
            governor.register(
                name: "clipboard-history",
                estimatedBytes: 256 * 1024,
                stage: .costly
            ) { [weak self] in
                Self.runOnMain {
                    self?.model.clipboardItems = []
                }
            }
        )

        // ③ 中文引擎：暂无对应资源，占位。
        //    `PinyinDictionary` 是引擎核心数据，释放后重建 15–25ms 会打断输入；
        //    且 `ios/Shared/IMECore` 未提供「只清临时缓存」的入口（不在本模块写作用域内）。
        memoryReclaimerTokens.append(
            governor.register(
                name: "pinyin-engine",
                estimatedBytes: 0,
                stage: .last
            ) {
                // 暂无对应资源，占位：待 Shared/IMECore 提供 clearTransientCaches() 后接入。
            }
        )

        // 注册完立刻启动采样（`viewWillAppear` 里还有一次幂等兜底）。
        startMemoryMonitoringIfNeeded()
    }

    /// 启动内存采样（幂等：`viewDidLoad` 与 `viewWillAppear` 都会调用）。
    private func startMemoryMonitoringIfNeeded() {
        guard !isMemoryMonitoring else { return }
        isMemoryMonitoring = true
        KMMemoryGovernor.shared.startMonitoring()
    }

    /// 停止内存采样（键盘收起时调用，下次弹出重新启动）。
    private func stopMemoryMonitoringIfNeeded() {
        guard isMemoryMonitoring else { return }
        isMemoryMonitoring = false
        KMMemoryGovernor.shared.stopMonitoring()
    }

    /// 在主线程执行回收动作（`@Published` 属性只能在主线程改；治理器的 Timer 本就在主线程）。
    private static func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
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

    /// 只同步高度约束常量，**不触发任何布局**。
    ///
    /// 专供 `viewWillLayoutSubviews` 使用：该方法本身就是布局过程的回调，
    /// 在其中调用 `layoutIfNeeded()` 会形成无限递归（真机栈溢出崩溃的根因）。
    /// 约束常量改变后，UIKit 会在本轮布局里自然生效，无需手动推动。
    private func syncHeightConstraintOnly() {
        let target = currentTargetHeight
        guard abs(target - appliedHeight) > 0.5 else { return }
        if let constraint = heightConstraint {
            if abs(constraint.constant - target) > 0.5 {
                constraint.constant = target
            }
        } else {
            setupHeightConstraint()
        }
        appliedHeight = target
        lastLandscape = isLandscapeLayout
        requestHeightUpdateFromSystem()
    }

    /// 应用目标高度（唯一改高度的地方）。
    ///
    /// 兼容方案说明：iOS 16 没有公开的 `requestInputViewHeightUpdate()`，
    /// 因此这里直接改 `heightAnchor` 常量并 `layoutIfNeeded()`，让宿主重新测量；
    /// 若未来系统提供该方法则通过 `responds(to:)` 转发，不产生编译期依赖。
    /// - Parameter animated: 是否使用弹簧动画（页面切换为 true，旋转/首次布局为 false）。
    private func applyHeight(animated: Bool) {
        // 重入保护：`layoutIfNeeded()` 会同步回调 `viewWillLayoutSubviews`，
        // 若不加锁会形成 applyHeight → layout → viewWillLayoutSubviews → applyHeight 的无限递归。
        guard isApplyingHeight == false else { return }
        isApplyingHeight = true
        defer { isApplyingHeight = false }

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
    ///
    /// - Important: 这里**只能 `setNeedsLayout()`，不能 `layoutIfNeeded()`**——
    ///   本方法会被 `viewWillLayoutSubviews` 路径（`syncHeightConstraintOnly`）调用，
    ///   在布局回调里强制布局就是真机栈溢出的根因。
    private func requestHeightUpdateFromSystem() {
        let selector = NSSelectorFromString(Self.heightUpdateSelectorName)
        if responds(to: selector) {
            perform(selector)
        }
        // 通知系统下一轮重新测量：`view` 就是本控制器的输入视图
        // （`UIInputViewController` 以 `view` 作为 inputView）。
        view.setNeedsLayout()
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
