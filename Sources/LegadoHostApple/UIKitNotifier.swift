import Foundation
import LegadoCore

#if canImport(UIKit)
import UIKit

/// ⭐ **iOS 的用户提示**（宿主服务契约 §S-HOST-06 的参考实现）。
///
/// ⚠️ **iOS 没有原生 toast** ⇒ 常见做法是自绘一个浮层。
/// ⇒ 这里实现一个**最简浮层**（淡入 + 停留 + 淡出）。
///
/// ⭐ **宿主注入「容器 view」**（通常是详情页/阅读页的根 view）⇒ 引擎不碰 UI 层级
///   ```swift
///   let notifier = UIKitNotifier(container: view)
///   ```
/// ⚠️ **调用线程**：`Notifier` 可能从后台线程被调 ⇒ 内部统一切到主线程。
public final class UIKitNotifier: Notifier, @unchecked Sendable {

    private weak var container: UIView?
    private let showSeconds: TimeInterval
    private let lock = NSLock()
    private var current: UIView?

    public init(container: UIView, showSeconds: TimeInterval = 2.0) {
        self.container = container
        self.showSeconds = showSeconds
    }

    public func notify(_ message: String) { show(message, isError: false) }
    public func notifyError(_ message: String) { show(message, isError: true) }

    private func show(_ message: String, isError: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let container = self.container else { return }
            // 同一时刻只留一个
            self.lock.lock()
            self.current?.removeFromSuperview()
            self.lock.unlock()

            let label = UILabel()
            label.text = message
            label.numberOfLines = 0
            label.textAlignment = .center
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .white
            label.backgroundColor = isError
                ? UIColor.systemRed.withAlphaComponent(0.92)
                : UIColor.black.withAlphaComponent(0.75)
            label.layer.cornerRadius = 8
            label.clipsToBounds = true
            label.alpha = 0

            container.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor,
                                             constant: -48),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor,
                                               constant: 24),
                label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                                constant: -24),
            ])
            container.layoutIfNeeded()

            self.lock.lock(); self.current = label; self.lock.unlock()
            UIView.animate(withDuration: 0.2) { label.alpha = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.showSeconds) {
                UIView.animate(withDuration: 0.25, animations: { label.alpha = 0 }) { _ in
                    label.removeFromSuperview()
                }
            }
        }
    }
}
#endif
