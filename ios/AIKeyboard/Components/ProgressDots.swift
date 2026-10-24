//
//  ProgressDots.swift
//  墨语 · 宿主 App 组件
//
//  三点跳动的「正在思考」指示器（契约：design/组件库.md L1 ProgressDots）。
//  用在流式输出刚开始、还没有任何文本到达的时候，避免出现空白区域。
//
import SwiftUI

/// 三个依次放大缩小的圆点。
struct ProgressDots: View {

    /// 圆点直径。
    var size: CGFloat = AppMetrics.glyphSizeSmall - AppMetrics.hairGap

    /// 圆点颜色。
    var tint: Color = Theme.textSecondary

    /// 动画进行到第几个点（0…2 循环）。
    @State private var activeIndex: Int = 0

    /// Reduce Motion 时不做缩放动画。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: AppMetrics.chipIconGap) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint)
                    .frame(width: size, height: size)
                    .opacity(activeIndex == index ? 1 : 0.35)
                    .scaleEffect(reduceMotion ? 1 : (activeIndex == index ? 1.15 : 0.85))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: Theme.Motion.normal), value: activeIndex)
        .onAppear {
            guard !reduceMotion else { return }
            startAnimating()
        }
        .accessibilityLabel(Text("正在思考"))
    }

    /// 用一个循环定时器轮换高亮点。
    private func startAnimating() {
        Timer.scheduledTimer(withTimeInterval: Theme.Motion.normal, repeats: true) { timer in
            if Task.isCancelled {
                timer.invalidate()
                return
            }
            DispatchQueue.main.async {
                activeIndex = (activeIndex + 1) % 3
            }
        }
    }
}

#if DEBUG
struct ProgressDots_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: AppMetrics.sectionGap) {
            ProgressDots()
            ProgressDots(size: AppMetrics.glyphSize, tint: Theme.accent)
        }
        .padding()
        .background(AppColor.pageBackground)
    }
}
#endif
