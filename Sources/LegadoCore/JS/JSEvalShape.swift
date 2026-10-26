import Foundation

/// ⭐⭐⭐⭐⭐ **求值形态**（跨平台 ⇒ Linux 沙盒也能类型检查）
///
/// ────────────────────────────────────────────────────────────
/// ⭐⭐⭐⭐⭐ **本文件是「形态」的【单一真相】**
///   · JSC 后端与 Node 后端**用同一份脚本文本** ⇒ **不可能漂移** ⭐⭐⭐
///   · 它是**纯 Foundation** ⇒ **Linux 沙盒能编** ⇒ 改错本地 3 秒抓到 ⭐⭐⭐
///   · 形态文本**只在这里生成** ⇒ Node harness 不再自己拼 ⇒ 零漂移 ⭐⭐⭐
///
/// ────────────────────────────────────────────────────────────
/// ⭐⭐⭐⭐⭐ **形态链 = 老引擎（轻阅 `rule-analyzer.js`）的同款**（2026-10-26 实测定稿）
/// ─────────────────────────────────────────────────────────────
/// 老引擎（真机跑得通的那套）的三形态：
/// ```
///   ① new Function(scope…, '__qrCode', 'return eval(__qrCode);')            // 直接 eval
///   ② new Function(scope…, '__qrCode', 'return eval("(" + __qrCode + ")");') // 整段当表达式
///   ③ new Function(scope…, '__qrCode', 'return eval("(function(){" + __qrCode + "\n})()");') // 整段当函数体
/// ```
/// ⇒ **只有抛【语法错】才换下一种形态**（老引擎原话：`e.name === 'SyntaxError'`）⭐⭐⭐
/// ⇒ **运行时错误（TypeError 等）直接抛** ⇒ **站方 JS 只执行一次** ⇒ 副作用不重复 ⭐⭐⭐
///
/// ────────────────────────────────────────────────────────────
/// ⭐⭐⭐⭐⭐ **JSC 的真实语义（2026-10-26 macOS CI 实测，不是猜的）**
/// ─────────────────────────────────────────────────────────────
/// | 写法 | JSC（`evaluateScript`） | V8/Node |
/// |---|---|---|
/// | `1+2` | 3 | 3 |
/// | `var a=1; a` | 1 | 1 |
/// | `let b=2; b` | 2（⚠️ **第二次跑 ⇒ 重复声明 SyntaxError**） | 2（✅ 不报错） |
/// | `{ 1+2 }`（块） | **3**（块完成值 ✅） | 3 |
/// | `{ name: 'x' }`（标签语句） | **"x"**（字符串 ✅） | "x" |
/// | `eval('let z=1; z;')` | 1（✅ **eval 里的 let 不重复声明**） | 1 |
/// | 语法错 | **异常处理器会被调**（值 = undefined） | throw |
///
/// ⭐⭐⭐ **两个致命的差异（旧结论是错的，本表是实测）**：
///   ① **JSC 的「块完成值」是好的** ⇒ 「JSC 的 eval 块返回 undefined」是**错的** ⭐⭐⭐
///   ② ⭐⭐⭐ **JSC 顶层脚本里的 `let` 是【全局词法声明】** ⇒ 同一段代码跑第二次 ⇒
///      `SyntaxError: Can't create duplicate variable` ⇒ **兜底形态也救不了**
///      （函数体形态没有 `return` ⇒ 值 = undefined）⇒ **静默空** ⭐⭐⭐⭐⭐
/// ⇒ ⇒ **正解 = 形态 ① 用【直接 eval】** ⇒ eval 里的 `let` 是 eval 自己的作用域
///      ⇒ **重复声明问题消失** ⇒ 且完成值语义与老引擎**逐字一致** ⭐⭐⭐⭐⭐
public enum JSEvalShape {

    /// ⭐⭐⭐⭐⭐ **该形态的脚本列表**（**两个后端用同一份** ⇒ 不可能漂移）⭐⭐⭐
    ///
    /// - Parameters:
    ///   - code: 站方代码
    ///   - scope: 引擎拼出来的作用域源码
    /// - Returns: 按老引擎顺序排的脚本（第一个是主形态）
    public static func scripts(for code: String, scope: String) -> [String] {
        // ⭐⭐⭐ **scope 后面必须补分号**（2026-10-25 实测的 Node 侧老 bug）
        //
        // ⚠️ scope 是 `var result = …;` 这种**声明**（末尾可能没有分号）
        // ⇒ scope 后面直接跟站方代码 ⇒ 声明后紧跟 `(` / `{` / `[`
        // ⇒ **ASI 不会插入分号** ⇒ 整个脚本语法错 ⇒ 所有形态全废 ⭐⭐⭐
        let sc = scope.trimmingCharacters(in: .whitespacesAndNewlines) + ";\n"
        return [
            // ⭐⭐⭐ **形态 ①：直接 eval**（主形态 = 老引擎同款）
            //   · 完成值 = 代码作为【脚本】的完成值（末行表达式 / 标签语句 / 块完成值）⭐⭐⭐
            //   · eval 里的 `let`/`const` 是**eval 自己的作用域** ⇒ 重复跑不炸 ⭐⭐⭐
            sc + "(function(){ return eval(" + jsonLiteral(code) + "); })()",
            // ⭐⭐⭐ **形态 ②：整段当表达式**（`@js:{a:1}` 这种对象字面量规则）
            //   ⚠️ 形态 ① 对 `{a:1}` 是**语法错**（标签语句带逗号不合法）⇒ 才轮到它 ⭐⭐⭐
            sc + "(function(){ return eval(" + jsonLiteral("(" + code + ")") + "); })()",
            // ⭐⭐⭐ **形态 ③：整段当函数体**（站方写 `return xxx;` 时才合法）⭐⭐⭐
            //   ⚠️ 末尾补换行 ⇒ 代码最后一行是 `//` 注释也不会把 `})()` 吃掉 ⭐⭐⭐
            sc + "(function(){ return eval("
                + jsonLiteral("(function(){" + code + "\n})()") + "); })()",
        ]
    }

    /// ⭐⭐⭐ **JSON 字符串字面量**（把 Swift 字符串变成 JS 里的字符串字面量）
    public static func jsonLiteral(_ s: String) -> String {
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
