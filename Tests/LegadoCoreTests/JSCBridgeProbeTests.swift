import Foundation
import XCTest
@testable import LegadoCore

#if canImport(JavaScriptCore)
import JavaScriptCore

/// ⭐⭐ **JSC 桥接探针** —— 一次性试遍所有可能的「Swift 闭包 → JSC」注入写法，
/// 打印每种写法的**实际结果** ⇒ 一轮 CI 就能定位到「哪种能用」，不用连猜带改。
///
/// ⚠️ 背景：`java.getString('hi')` 之前返回空串 ⇒ 怀疑是**宿主 block 没被真正注入**
/// （`unsafeBitCast` 到 `AnyObject` 可能不被 Xcode 26 的 JSC 接受）。
/// ⇒ 这里把候选写法全试一遍。
final class JSCBridgeProbeTests: XCTestCase {

    /// 每种写法：名字 + 注入动作
    private struct Candidate {
        let name: String
        let inject: (JavaScriptCore.JSContext, @escaping (String, String, String) -> String) -> Void
    }

    private func candidates() -> [Candidate] {
        [
            // ① unsafeBitCast → AnyObject
            Candidate(name: "unsafeBitCast→AnyObject") { js, host in
                let block: @convention(block) (String, String, String) -> String = { o, m, a in
                    host(o, m, a)
                }
                js.setObject(unsafeBitCast(block, to: AnyObject.self),
                             forKeyedSubscript: "__hostJSON" as NSString)
            },
            // ② 直接传 block（老 API 的标准用法）
            Candidate(name: "直接传 block") { js, host in
                let block: @convention(block) (String, String, String) -> String = { o, m, a in
                    host(o, m, a)
                }
                js.setObject(block, forKeyedSubscript: "__hostJSON" as NSString)
            },
            // ③ 塞进一个 JS 对象里（`js.objectForKeyedSubscript` 再设）
            Candidate(name: "经 JS 对象中转") { js, host in
                let block: @convention(block) (String, String, String) -> String = { o, m, a in
                    host(o, m, a)
                }
                _ = js.evaluateScript("var __h = {};")
                if let h = js.objectForKeyedSubscript("__h" as NSString) {
                    h.setObject(block, forKeyedSubscript: "call" as NSString)
                }
                js.setObject(js.objectForKeyedSubscript("__h" as NSString),
                             forKeyedSubscript: "__hostJSON" as NSString)
            },
            // ④ 不用 block：把宿主实现**编译成 JS 源码**（拿不到 Swift ⇒ 只验「能不能跑」）
            Candidate(name: "纯 JS（对照组）") { js, _ in
                _ = js.evaluateScript("var __hostJSON = function(o,m,a){ return '[\"'+o+'\"]'; };")
            },
        ]
    }

    func testProbeAllBridgeCandidates() throws {
        var report: [String] = []
        for c in candidates() {
            guard let js = JavaScriptCore.JSContext() else { continue }
            c.inject(js) { o, m, a in
                // 宿主侧：把收到的参数**原样回显**（这样能看出参数到底传没传过来）
                let args = a == "[]" ? "<空>" : a
                return "[\"\(o)\",\"\(m)\",\(args)]"
            }
            // ① 直接调 block
            let direct = js.evaluateScript("__hostJSON('java','getString',JSON.stringify(['hi']))")
            // ② 经 JS 包装函数调（模拟站方用法）
            let wrapped = js.evaluateScript("""
            (function(){
              var __args = Array.prototype.slice.call(arguments);
              var __r = __hostJSON('java','getString', JSON.stringify(__args));
              return String(__r);
            })('hi')
            """)
            // ③ 参数个数验证：站方传 1 个、2 个时分别回显
            let twoArgs = js.evaluateScript("""
            (function(){
              var __args = Array.prototype.slice.call(arguments);
              return String(__hostJSON('java','ajax', JSON.stringify(__args)));
            })('url', {method:'POST'})
            """)
            report.append("[\(c.name)] direct=\(direct.map { String(describing: $0) } ?? "nil") wrapped=\(wrapped.map { String(describing: $0) } ?? "nil") two=\(twoArgs.map { String(describing: $0) } ?? "nil")")
        }
        print("===JSC-BRIDGE-PROBE===")
        for r in report { print("PROBE " + r) }
        print("===END-PROBE===")
    }
}
#endif
