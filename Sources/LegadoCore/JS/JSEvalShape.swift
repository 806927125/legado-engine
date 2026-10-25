import Foundation

/// ⭐⭐⭐⭐⭐ **求值形态选择**（跨平台 ⇒ Linux 沙盒也能类型检查）
///
/// ────────────────────────────────────────────────────────────
/// 为什么要抽出来（2026-10-26 真机回归：JM小说 0 本书）
/// ────────────────────────────────────────────────────────────
///   · 形态选择逻辑原本在 `JSCExecutor.swift`（**平台专属** ⇒ Linux 根本不编译）
///     ⇒ 改错了本地看不见 ⇒ **连栽四次「Linux 全绿、macOS CI 编译失败」** ⭐⭐⭐
///   · 而且 **JSC 与 Node 的 eval/完成值语义本来就不同** ⇒ 各自写一套 ⇒ **必然漂移** ⭐⭐⭐
///
/// ⭐⭐⭐⭐⭐ **本文件是「形态选择」的【单一真相】**
///   · 两个后端都调它 ⇒ **不可能漂移** ⭐⭐⭐
///   · 它是**纯 Foundation** ⇒ **Linux 沙盒能编** ⇒ 改错本地 3 秒抓到 ⭐⭐⭐
///
/// ────────────────────────────────────────────────────────────
/// 两个后端的语义差异（**实测得出，不要凭印象改**）
/// ────────────────────────────────────────────────────────────
/// | 形态 | JSC（`evaluateScript`） | Node（`vm.runInContext`） |
/// |---|---|---|
/// | 顶层 `code` | ✅ **末行表达式的值**（脚本完成值） | ✅ 末行表达式的值 |
/// | `{ expr }`（块语句） | ❌ **undefined**（块语句完成值） | ✅ **块内最后表达式** |
/// | `eval('{ code }')` | ❌ undefined（eval 的脚本完成值 = 块语句） | ✅ **块内最后表达式** |
/// | 顶层 `let` 重复声明 | ❌ **SyntaxError**（全局词法声明） | ❌ SyntaxError |
///
/// ⇒ ⇒ **JSC 的主力形态 = 顶层**（脚本完成值）⭐⭐⭐
/// ⇒ ⇒ **Node 的主力形态 = `eval('{ code }')`**（eval 完成值 + 块作用域 ⇒ let 不重复声明）⭐⭐⭐
/// ⇒ ⇒ **两边形态故意不同** ⇒ 但**选择逻辑共用本文件** ⇒ 不会漂移 ⭐⭐⭐
///
/// ⭐⭐⭐⭐⭐ **副作用纪律**：形态**只跑一次**
///   · 「顶层有 return」⇒ 直接用函数体形态（`return` 只在函数体里合法）⭐⭐⭐
///   · 主力形态**抛错**才追加一次兜底 ⇒ ⇒ `java.ajax` 不会被重复调（限流）⭐⭐⭐
public enum JSEvalShape {

    /// ⭐⭐⭐ **形态**
    public enum Plan: Equatable, Sendable {
        /// ⭐⭐⭐ **对象字面量**（首尾 `{ }`）⇒ 「整段当表达式」
        ///   ⇒ 当脚本跑 ⇒ `{a:1}` 是**语句块** ⇒ 无值 ⭐⭐⭐
        case objectLiteral
        /// ⭐⭐⭐ **顶层有 `return`** ⇒ 「函数体形态」（顶层 return 只在函数体里合法）⭐⭐⭐
        case topLevelReturn
        /// ⭐⭐⭐ **常规** ⇒ 「主力形态」
        case script
    }

    /// ⭐⭐⭐⭐⭐ **选形态**（纯逻辑 ⇒ 两个后端共用 ⇒ 不会漂移）⭐⭐⭐
    public static func plan(for code: String) -> Plan {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            return .objectLiteral
        }
        if hasTopLevelReturn(code) {
            return .topLevelReturn
        }
        return .script
    }

    /// ⭐⭐⭐⭐⭐ **顶层 `return` 判定**（词法扫描：只看括号深度 0 的 `return`）
    ///
    /// ⚠️⚠️ **深度 > 0 的 `return` 属于函数体内** ⇒ **不算顶层 return**
    ///   ⇒ 否则 `(function(){ return []; })()` 会被误判 ⇒ 整条规则死 ⭐⭐⭐
    public static func hasTopLevelReturn(_ code: String) -> Bool {
        let src = Array(code.utf8)
        var depth = 0
        var i = 0
        let n = src.count
        let isWordChar: (UInt8) -> Bool = { c in
            (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
                || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x24
        }
        func at(_ k: Int) -> UInt8 { k < n ? src[k] : 0x20 }
        while i < n {
            let c = at(i)
            // 跳过字符串
            if c == 0x22 || c == 0x27 || c == 0x60 {
                let q = c
                i += 1
                while i < n {
                    if at(i) == 0x5C { i += 2; continue }
                    if at(i) == q { break }
                    i += 1
                }
                i += 1
                continue
            }
            // 跳过行注释
            if c == 0x2F && at(i + 1) == 0x2F {
                while i < n && at(i) != 0x0A { i += 1 }
                continue
            }
            // 跳过块注释
            if c == 0x2F && at(i + 1) == 0x2A {
                i += 2
                while i + 1 < n && !(at(i) == 0x2A && at(i + 1) == 0x2F) { i += 1 }
                i += 2
                continue
            }
            if c == 0x28 || c == 0x5B || c == 0x7B { depth += 1; i += 1; continue }
            if c == 0x29 || c == 0x5D || c == 0x7D { depth -= 1; i += 1; continue }
            if depth == 0, i + 6 <= n,
               String(decoding: src[i..<(i + 6)], as: UTF8.self) == "return",
               !(i + 6 < n && isWordChar(at(i + 6))) {
                return true
            }
            i += 1
        }
        return false
    }

    /// ⭐⭐⭐⭐⭐ **生成该形态的脚本**（两个后端共用同一套判定 ⇒ 形态选择不会漂移）⭐⭐⭐
    ///
    /// - Parameters:
    ///   - backend: `.jsc` / `.node` ⇒ **只有「主力形态」的写法不同**，其余完全一致 ⭐⭐⭐
    ///   - scope: 引擎拼出来的作用域源码
    ///   - code: 站方代码
    public enum Backend: Sendable { case jsc, node }

    /// ⭐⭐⭐ **该形态的脚本列表**（第一个是主力；第二个是「主力抛错」时的兜底）⭐⭐⭐
    public static func scripts(for plan: Plan, backend: Backend,
                              scope: String, code: String) -> [String] {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        switch plan {
        case .objectLiteral:
            // ⭐⭐⭐ **对象字面量 ⇒ 整段当表达式**（两个后端一致）⭐⭐⭐
            return [scope + "\n(" + trimmed + "\n)"]
        case .topLevelReturn:
            // ⭐⭐⭐ **顶层有 return ⇒ 函数体形态**（两个后端一致）⇒ **只跑一次** ⭐⭐⭐
            return [scope + "\n(function(){\n" + trimmed + "\n})()"]
        case .script:
            switch backend {
            case .jsc:
                // ⭐⭐⭐ **JSC：顶层形态**（`evaluateScript` 返回脚本完成值 = 末行表达式）⭐⭐⭐
                //   ⚠️ 顶层 `let` 会是**全局词法声明** ⇒ 第二次跑重复声明 ⇒ SyntaxError
                //   ⇒ 兜底形态也要能处理 ⇒ 见下
                return [scope + "\n" + trimmed,
                        scope + "\n(function(){\n" + trimmed + "\n})()"]
            case .node:
                // ⭐⭐⭐ **Node：`eval('{ code }')`**（eval 完成值 = 块内最后表达式）
                //   ⇒ 块作用域 ⇒ 顶层 `let` 不留 ctx ⇒ 重复声明不会炸 ⭐⭐⭐
                return [scope + "\n(function(){ return eval("
                        + jsonLiteral("{ " + code + " }") + "); })()",
                        scope + "\n(function(){\n" + trimmed + "\n})()"]
            }
        }
    }

    /// ⭐⭐⭐ **JSON 字符串字面量**（把 Swift 字符串变成 JS 里的字符串字面量）
    private static func jsonLiteral(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }
}
