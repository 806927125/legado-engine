import Foundation
import XCTest
@testable import LegadoCore

#if canImport(JavaScriptCore)
import JavaScriptCore

/// ⭐⭐⭐⭐⭐ **JSC 语义探针**（2026-10-26）
///
/// ────────────────────────────────────────────────────────────
/// 为什么需要这个文件（**别再猜 JSC 的语义了**）
/// ─────────────────────────────────────────────────────────────
///   · JSC 与 Node（V8）的 **eval / 完成值 / 语法错** 语义**不一样**
///   · Linux 沙盒**没有 JavaScriptCore** ⇒ 沙盒门禁验不到 JSC 路径
///   ⇒ 以前只能「在真机上撞」⇒ 一轮一个洞 ⇒ 极慢
/// ⇒ ⭐ **这里一次把 JSC 的原始语义全测出来** ⇒ 一轮 CI 拿到全部答案
///
/// ⭐⭐⭐ **测量方式**：
///   ① **原始 JSContext**（不经过引擎）⇒ 测 JSC 语言本身的语义
///   ② **JSCExecutor**（经过引擎）⇒ 测「引擎这条链」的最终行为
///   ⇒ 两层对照 ⇒ 差异就是**引擎的锅**（而不是 JSC 的锅）⭐⭐⭐
///
/// ⭐⭐⭐ **输出用 `print`** ⇒ CI 原始日志里能直接看到
///   （已实测：Linux job 的 `print` 确实进了 CI 日志）
final class JSCSemanticsProbeTests: XCTestCase {

    // MARK: - 原始 JSC 语义

    /// ⭐⭐⭐ **描述一个 JSValue**（区分 undefined / null / 对象 / 数组）
    private func describe(_ v: JSValue?) -> String {
        guard let v else { return "nil（evaluateScript 没返回值）" }
        if v.isUndefined { return "undefined" }
        if v.isNull { return "null" }
        if v.isBoolean { return "bool(\(v.toBool()))" }
        if v.isNumber { return "number(\(v.toDouble()))" }
        if v.isString { return "string(\(v.toString() ?? "<nil>"))" }
        if v.isArray {
            let items = (v.toArray() ?? []).compactMap { $0 as? JSValue }
            return "array(len=\(items.count))"
        }
        if v.isObject {
            var keys: [String] = []
            for (k, _) in (v.toDictionary() ?? [:]) {
                if let ks = k as? String { keys.append(ks) }
            }
            return "object(keys=\(keys.sorted().joined(separator: ",")))"
        }
        return "其它(\(v.toString() ?? "?"))"
    }

    /// ⭐⭐⭐ **在指定 context 里跑一段脚本** ⇒ 返回「值 + 异常处理器有没有被调」
    private func raw(_ script: String, in ctx: JavaScriptCore.JSContext) -> String {
        final class Box: @unchecked Sendable { var value: String? }
        let caught = Box()
        ctx.exceptionHandler = { (_, exception: JSValue?) in
            if let exception { caught.value = String(describing: exception) }
        }
        let v = ctx.evaluateScript(script)
        let handler = caught.value.map { "异常处理器=被调(\($0.prefix(60)))" } ?? "异常处理器=没被调"
        return "\(describe(v)) | \(handler)"
    }

    func testProbeJSCRawSemantics() throws {
        let ctx = try XCTUnwrap(JavaScriptCore.JSContext())
        var lines: [String] = []
        lines.append("【A】完成值语义")
        for (name, script) in [
            ("数字表达式", "1+2"),
            ("var+末行", "var a=1; a"),
            ("let+末行", "let b=2; b"),
            ("块语句", "{ 1+2 }"),
            ("括号对象", "({ name: '书名' })"),
            ("裸对象", "{ name: '书名' }"),
        ] {
            lines.append("  \(name) | \(raw(script, in: ctx))")
        }

        lines.append("【B】eval 语义")
        for (name, script) in [
            ("eval纯表达式", "eval('1+2')"),
            ("eval块", "eval('{ 1+2 }')"),
            ("eval带var", "eval('var a=1; a')"),
            ("eval带let", "eval('let z=1; z;')"),
            ("eval块带let", "eval('{ let z=1; z; }')"),
            ("函数体包eval", "(function(){ return eval('var a=1; a'); })()"),
            ("函数体包eval纯表达式", "(function(){ return eval('1+2'); })()"),
            ("函数体包eval块", "(function(){ return eval('{ 1+2 }'); })()"),
        ] {
            lines.append("  \(name) | \(raw(script, in: ctx))")
        }
        // ⭐⭐⭐ **同一个 context 里重复 eval 带 let 的代码**（eval 的 let 是 eval 自己的作用域 ⇒ 不该重复声明）
        lines.append("  eval-let第1次 | \(raw("eval('let dup2=1; dup2;')", in: ctx))")
        lines.append("  eval-let第2次 | \(raw("eval('let dup2=1; dup2;')", in: ctx))")
        lines.append("  eval-var第1次 | \(raw("eval('var dup3=1; dup3;')", in: ctx))")
        lines.append("  eval-var第2次 | \(raw("eval('var dup3=1; dup3;')", in: ctx))")

        lines.append("【C】语法错 / 重复声明（同一个 context）")
        for (name, script) in [
            ("真语法错", "this is ) not ( valid"),
            ("顶层return", "return 7;"),
        ] {
            lines.append("  \(name) | \(raw(script, in: ctx))")
        }
        // ⭐ 重复的顶层 let（**同一个 context 连跑两次** ⇒ 第 2 次应报重复声明）
        lines.append("  第1次顶层let | \(raw("let dup=1; dup;", in: ctx))")
        lines.append("  第2次顶层let | \(raw("let dup=1; dup;", in: ctx))")
        lines.append("  第3次(函数体形态) | \(raw("(function(){ let dup=1; dup; })()", in: ctx))")
        lines.append("  第4次(函数体+显式return) | \(raw("(function(){ let dup=1; return dup; })()", in: ctx))")

        lines.append("【D】引擎链（JSCExecutor）")
        let exec = JSCExecutor(api: ProbeAPI())
        let runCtx = JSRunContext(base: .page(""), baseUrl: "https://x.example/")
        for (name, code) in [
            ("数字表达式", "1+2"),
            ("var+末行", "var b = 5; b * 2"),
            ("var+末行2", "var a=1; a"),
            ("块语句", "{ 1+2 }"),
            ("裸对象", "{ name: '书名', author: '作者' }"),
            ("裸对象单字段", "{ name: '书名' }"),
            ("括号对象", "({ name: '书名', author: '作者' })"),
            ("IIFE返回数组", "(function(){ return []; })()"),
            ("IIFE返回非空", "(function(){ return ['x']; })()"),
            ("顶层return", "return 'id=' + '7';"),
        ] {
            do {
                let v = try exec.run(code, context: runCtx)
                lines.append("  \(name) | \(self.describeJSON(v))")
            } catch {
                lines.append("  \(name) | 抛错 \(String(describing: error).prefix(120))")
            }
        }
        // ⭐⭐⭐ **同一段带 let 的代码跑两次**（真机「重复声明」的老坑）
        do {
            let v1 = try exec.run("let device_type = '安卓'; device_type;", context: runCtx)
            lines.append("  引擎·let第1次 | \(self.describeJSON(v1))")
        } catch {
            lines.append("  引擎·let第1次 | 抛错 \(String(describing: error).prefix(120))")
        }
        do {
            let v2 = try exec.run("let device_type = '安卓'; device_type;", context: runCtx)
            lines.append("  引擎·let第2次 | \(self.describeJSON(v2))")
        } catch {
            lines.append("  引擎·let第2次 | 抛错 \(String(describing: error).prefix(120))")
        }

        let report = lines.joined(separator: "\n")
        print("========== JSC 语义探针 ==========\n\(report)\n==============================")
        XCTAssertFalse(report.isEmpty, "探针必须产出内容")
    }

    /// ⭐⭐⭐ **描述一个 JSONValue**（引擎链的最终形态）
    private func describeJSON(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return "bool(\(b))"
        case .int(let i): return "int(\(i))"
        case .double(let d): return "double(\(d))"
        case .string(let s): return "string(\(s))"
        case .array(let a): return "array(len=\(a.count))"
        case .object(let o):
            let keys = o.keys.sorted().joined(separator: ",")
            return "object(keys=\(keys))"
        }
    }

    /// ⭐⭐⭐ **空宿主**（探针不关心宿主行为）
    final class ProbeAPI: JSHostAPIProvider, @unchecked Sendable {
        func hostObject(named name: String) -> HostObject? { nil }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? { nil }
    }
}
#else
/// ⭐⭐⭐ **Linux 上整个文件跳过**（没 JSC ⇒ **没验到**，不等于通过）
final class JSCSemanticsProbeTests: XCTestCase {
    func testSkippedOnLinuxBecauseNoJSC() {
        print("⏭️ 跳过：Linux 没有 JavaScriptCore ⇒ JSC 语义探针**没跑到**（不等于通过）")
    }
}
#endif
