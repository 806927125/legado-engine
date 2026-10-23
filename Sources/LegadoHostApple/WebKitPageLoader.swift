import Foundation
import LegadoCore

#if canImport(WebKit)
import WebKit

/// ⭐⭐ **WKWebView 的【同步】加载器** —— 宿主服务契约 §S-HOST-04（浏览器）的零件。
///
/// ⚠️ **为什么需要它**：引擎的 `BrowserProvider.fetchSource` 是**同步**契约
///   （站方 `java.startBrowserAwait` 要同步拿回页面源码）
///   ⇒ WebKit 本身是**异步**的 ⇒ 必须「加载 + 泵 RunLoop + 等导航完成」。
///
/// ⭐ **本类不碰 UI 层级** ⇒ 宿主把**自己的** `WKWebView` 传进来即可：
/// ```swift
/// let loader = WebKitPageLoader()
/// let html = loader.load(myWebView, url: "https://x/login", timeout: 30)
/// ```
///
/// ⚠️ **必须在主线程调用**（WebKit 要求）⇒ 引擎全同步 ⇒ 宿主在主线程跑流水线即可。
public final class WebKitPageLoader: NSObject, WKNavigationDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var finished = false
    private var failed = false
    private var html: String = ""

    public override init() { super.init() }

    /// ⭐ **同步加载并取回页面源码**；超时或失败 ⇒ nil
    @discardableResult
    public func load(_ webView: WKWebView, url: String, timeout: TimeInterval = 30) -> String? {
        guard let u = URL(string: url) else { return nil }
        lock.lock()
        finished = false; failed = false; html = ""
        lock.unlock()

        webView.navigationDelegate = self
        webView.load(URLRequest(url: u))

        let deadline = Date().addingTimeInterval(timeout)
        // ⭐ **泵 RunLoop**（WebKit 的回调要主线程 RunLoop 才会来）
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            lock.lock()
            let done = finished || failed
            lock.unlock()
            if done { break }
        }
        lock.lock(); defer { lock.unlock() }
        return failed ? nil : html
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] res, _ in
            guard let self else { return }
            self.lock.lock()
            self.html = (res as? String) ?? ""
            self.finished = true
            self.lock.unlock()
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail()
    }

    private func fail() {
        lock.lock(); failed = true; finished = true; lock.unlock()
    }
}
#endif
