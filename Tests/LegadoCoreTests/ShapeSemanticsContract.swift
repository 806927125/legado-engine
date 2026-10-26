import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **求值形态的【契约】** —— **两个后端都必须满足同一份** ⭐⭐⭐⭐⭐
///
/// ────────────────────────────────────────────────────────────
/// 为什么要有它（2026-10-26 真机回归：JM小说 0 本书）
/// ─────────────────────────────────────────────────────────────
///   · JSC 后端**只在 macOS CI 能验** ⇒ 反馈慢（一次 CI ≈ 5 分钟）
///   · Node 后端**在 Linux 沙盒就能验** ⇒ 反馈快（3 秒）
///   ⇒ ⭐ **把「形态语义」写成【一份契约】⇒ 两个后端各跑一遍**
///   ⇒ 沙盒先过（快）⇒ 再上 macOS CI 验 JSC（慢）⇒ **且两边不可能漂移** ⭐⭐⭐
///
/// ⭐⭐⭐ **期望值来自【老引擎】（轻阅 `rule-analyzer.js`）的实测语义**
///   —— 老引擎是真机跑得通的那套 ⇒ 它就是**事实标准** ⭐⭐⭐⭐⭐
enum ShapeSemanticsContract {

    /// ⭐⭐⭐ **一条契约**
    struct Case {
        let name: String
        /// 站方代码
        let code: String
        /// 期望的**规范化结果**（用 `describe` 生成 ⇒ 两个后端可比）
        let expected: String
    }

    /// ⭐⭐⭐⭐⭐ **契约清单**（2026-10-26 macOS CI + Node 实测定稿）⭐⭐⭐⭐⭐
    static let cases: [Case] = [
        // ① 完成值语义（末行表达式 = Legado 主语义）
        Case(name: "数字表达式", code: "1+2", expected: "3"),
        Case(name: "var+末行", code: "var a=1; a", expected: "1"),
        Case(name: "字符串拼接", code: "'a' + 'b'", expected: "ab"),
        Case(name: "赋值表达式", code: "result = String(123);", expected: "123"),
        // ② 块完成值（**JSC 也支持** ⇒ 以前"JSC 的块返回 undefined"是错的）
        Case(name: "块完成值", code: "{ 1+2 }", expected: "3"),
        // ③ 标签语句（`{ name: 'x' }` 在脚本里是**标签**⇒ 完成值 = 'x'）
        Case(name: "标签语句", code: "{ name: '书名' }", expected: "书名"),
        // ④ 对象字面量（两字段 ⇒ 形态 ① 是语法错 ⇒ 落到形态 ② ⇒ 对象）
        Case(name: "对象字面量(两字段)", code: "{ name: '书名', author: '作者' }",
             expected: "object{author=作者,name=书名}"),
        Case(name: "括号对象", code: "({ a: 1, b: 'x' })", expected: "object{a=1,b=x}"),
        // ⑤ 数组（**内容不许丢** ⇒ 真机「0 本书 / 0 章」的头号真凶）
        Case(name: "数组", code: "[1,2,3]", expected: "array[1,2,3]"),
        Case(name: "IIFE返回空数组", code: "(function(){ return []; })()", expected: "array[]"),
        Case(name: "IIFE返回非空数组", code: "(function(){ return ['x']; })()", expected: "array[x]"),
        // ⑥ 顶层 return（形态 ①② 语法错 ⇒ 形态 ③ 函数体）
        Case(name: "顶层return", code: "return 'id=' + '7';", expected: "id=7"),
        // ⑦ let（**eval 作用域** ⇒ 同一段代码跑两次不炸 ⇒ 真机「重复声明」的老坑）
        Case(name: "let末行", code: "let device_type = '安卓'; device_type;", expected: "安卓"),
    ]

    /// ⭐⭐⭐ **规范化描述**（两个后端的结果要能逐字比 ⇒ 数字/字符串统一走 scalarString）
    static func describe(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return "bool(\(b))"
        case .int(let i): return "\(i)"
        case .double(let d): return RuleValue.numberToString(d)
        case .string(let s): return s
        case .array(let a): return "array[" + a.map { describe($0) }.joined(separator: ",") + "]"
        case .object(let o):
            let body = o.keys.sorted()
                .map { "\($0)=\(describe(o[$0]!))" }
                .joined(separator: ",")
            return "object{" + body + "}"
        }
    }

    /// ⭐⭐⭐⭐⭐ **跑一遍契约**（**两个后端各跑一次** ⇒ 同一份契约 ⇒ 不会漂移）⭐⭐⭐⭐⭐
    ///
    /// - Parameter run: 跑站方代码的入口（`JSCExecutor.run` / `NodeJSExecutor.run`）
    static func check(_ label: String, _ run: (String) throws -> JSONValue) throws {
        for c in cases {
            let actual: String
            do {
                actual = describe(try run(c.code))
            } catch {
                actual = "抛错(\(error))"
            }
            XCTAssertEqual(actual, c.expected,
                           "⭐⭐⭐ [\(label)] 形态语义不符 ⇒ 「\(c.name)」"
                           + " ⇒ 期望=\(c.expected) 实际=\(actual)")
        }
    }

    /// ⭐⭐⭐⭐⭐ **重复跑同一段含 `let` 的代码**（真机「重复声明」的老坑）⭐⭐⭐⭐⭐
    static func checkRepeatedLet(_ label: String, _ run: (String) throws -> JSONValue) throws {
        let code = "let device_type = '安卓'; device_type;"
        for i in 1...3 {
            let v = describe(try run(code))
            XCTAssertEqual(v, "安卓",
                           "⭐⭐⭐ [\(label)] 第 \(i) 次跑必须都成功（重复声明的老坑）⇒ 实际=\(v)")
        }
    }
}
