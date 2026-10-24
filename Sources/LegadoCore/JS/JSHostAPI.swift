import Foundation

/// **JS 宿主 API 契约** —— 站方 JS 能调用的宿主能力**清单**。
///
/// ⭐ **这份清单是「实证」来的，不是拍脑袋列的**：
/// 扫了 **大灰狼聚合 vip完全版**（jsLib 31,961 字节 + loginUrl 61,678 字节
/// + 9 处规则级 JS）+ **125 源包**的全部 JS 片段 ⇒ 抽出实际调用到的宿主 API。
/// ⇒ 数量：**大灰狼 49 个**（java 24 / source 7 / book 9 / chapter 1 / cookie 4 / cache 4）
///    ＋ 125 源补充（`java.getString` / `java.md5Encode` / `java.base64Decode` / `java.t2s` / …）。
///
/// ⚠️ **契约与实现分离**：
/// - 这里只定义**有哪些 API、参数返回什么形态**
/// - **具体实现由宿主给**（`JSHostAPIProvider`）⇒ 引擎不碰 URLSession / WKWebView
/// - 宿主**少实现一个** ⇒ 引擎在诊断里明说「宿主缺 xxx」⇒ 而不是让站方 JS 报 `undefined is not a function`
public enum JSHostAPI {

    /// 一个 API 条目
    public struct Entry: Sendable, Equatable {
        public enum Kind: String, Sendable { case method, property }
        public let object: String      // `java` / `source` / `book` / …
        public let name: String
        public let kind: Kind
        public init(object: String, name: String, kind: Kind) {
            self.object = object; self.name = name; self.kind = kind
        }
        public var key: String { "\(object).\(name)" }
    }

    // MARK: - 清单

    /// **方法**类 API（JS 里带括号调用的）
    public static let methods: [Entry] = [
        // ── java.*（站方最常用）
        .init(object: "java", name: "searchBook", kind: .method),
        .init(object: "java", name: "randomUUID", kind: .method),
        .init(object: "java", name: "connect", kind: .method),
        // ⭐⭐ **2026-10-23 从 125 源自动扫描补齐**（usage.json 里原来漏了这 3 个）
        //   ⇒ 契约漏 = JS 侧**不生成包装函数** ⇒ 站方调用报「undefined is not a function」⭐
        .init(object: "java", name: "toNumChapter", kind: .method),
        .init(object: "java", name: "timeFormatUTC", kind: .method),
        .init(object: "java", name: "refreshTocUrl", kind: .method),
        .init(object: "java", name: "ajaxAll", kind: .method),
        .init(object: "java", name: "log", kind: .method),
        .init(object: "java", name: "toast", kind: .method),
        .init(object: "java", name: "longToast", kind: .method),
        .init(object: "java", name: "ajax", kind: .method),
        .init(object: "java", name: "get", kind: .method),
        .init(object: "java", name: "post", kind: .method),
        .init(object: "java", name: "put", kind: .method),
        .init(object: "java", name: "getString", kind: .method),
        .init(object: "java", name: "getElement", kind: .method),
        .init(object: "java", name: "getElements", kind: .method),
        .init(object: "java", name: "setContent", kind: .method),
        .init(object: "java", name: "getAbsoluteURL", kind: .method),
        .init(object: "java", name: "base64Encode", kind: .method),
        .init(object: "java", name: "base64Decode", kind: .method),
        .init(object: "java", name: "hexDecodeToString", kind: .method),
        .init(object: "java", name: "md5Encode", kind: .method),
        .init(object: "java", name: "digestHex", kind: .method),
        .init(object: "java", name: "timeFormat", kind: .method),
        .init(object: "java", name: "t2s", kind: .method),
        .init(object: "java", name: "deviceID", kind: .method),
        .init(object: "java", name: "androidId", kind: .method),
        .init(object: "java", name: "getWebViewUA", kind: .method),
        .init(object: "java", name: "getCookie", kind: .method),
        .init(object: "java", name: "qread", kind: .method),
        .init(object: "java", name: "createSymmetricCrypto", kind: .method),
        // 浏览器 / 登录交接（引擎内部**唯一**的异步点）
        .init(object: "java", name: "startBrowser", kind: .method),
        .init(object: "java", name: "startBrowserAwait", kind: .method),
        .init(object: "java", name: "startBrowserDp", kind: .method),
        .init(object: "java", name: "showBrowser", kind: .method),
        .init(object: "java", name: "showReadingBrowser", kind: .method),
        .init(object: "java", name: "reLoginView", kind: .method),
        .init(object: "java", name: "refreshExplore", kind: .method),

        // ── source.*
        .init(object: "source", name: "header", kind: .property),
        .init(object: "source", name: "putVariable", kind: .method),
        .init(object: "source", name: "getVariable", kind: .method),
        .init(object: "source", name: "setVariable", kind: .method),
        .init(object: "source", name: "getLoginInfoMap", kind: .method),
        .init(object: "source", name: "getLoginInfo", kind: .method),
        .init(object: "source", name: "putLoginInfo", kind: .method),
        .init(object: "source", name: "loginUi", kind: .method),
        .init(object: "source", name: "getKey", kind: .method),

        // ── book.*
        .init(object: "book", name: "getVariable", kind: .method),
        .init(object: "book", name: "putVariable", kind: .method),
        .init(object: "book", name: "readConfig", kind: .method),
        .init(object: "book", name: "setUseReplaceRule", kind: .method),

        // ── chapter.*
        // ── cookie.*
        .init(object: "cookie", name: "getCookie", kind: .method),
        .init(object: "cookie", name: "setCookie", kind: .method),
        .init(object: "cookie", name: "removeCookie", kind: .method),
        .init(object: "cookie", name: "getKey", kind: .method),

        // ── cache.*
        .init(object: "cache", name: "put", kind: .method),
        .init(object: "cache", name: "get", kind: .method),
        .init(object: "cache", name: "putMemory", kind: .method),
        .init(object: "cache", name: "getFromMemory", kind: .method),
    ]

    /// **属性**类 API（JS 里**不带括号**读的）
    public static let properties: [Entry] = [
        .init(object: "source", name: "bookSourceUrl", kind: .property),
        .init(object: "source", name: "bookSourceComment", kind: .property),
        .init(object: "source", name: "bookSourceName", kind: .property),
        .init(object: "source", name: "key", kind: .property),
        .init(object: "book", name: "name", kind: .property),
        .init(object: "book", name: "intro", kind: .property),
        .init(object: "book", name: "type", kind: .property),
        .init(object: "book", name: "bookUrl", kind: .property),
        .init(object: "book", name: "variable", kind: .property),
        .init(object: "book", name: "imageStyle", kind: .property),
        .init(object: "book", name: "durChapterIndex", kind: .property),
        .init(object: "book", name: "durChapterTitle", kind: .property),
        .init(object: "book", name: "order", kind: .property),
        .init(object: "chapter", name: "wordCount", kind: .property),
        .init(object: "chapter", name: "sort", kind: .property),
        .init(object: "chapter", name: "nid", kind: .property),
        .init(object: "chapter", name: "chapterContent", kind: .property),
        .init(object: "chapter", name: "api", kind: .property),
        .init(object: "chapter", name: "substring", kind: .method),
        .init(object: "chapter", name: "index", kind: .property),
        .init(object: "chapter", name: "chapter_name", kind: .property),
    ]

    /// 全部条目
    public static var all: [Entry] { methods + properties }

    /// key → 条目（`java.ajax` 这样的全名）
    public static let index: [String: Entry] = {
        var m: [String: Entry] = [:]
        for e in all { m[e.key] = e }
        return m
    }()

    /// 契约里有哪些宿主对象
    public static var objects: Set<String> { Set(all.map { $0.object }) }
}

/// **宿主 API 的提供者** —— 宿主 App 实现它，JSC/Node 执行器把方法包成 JS 函数注入。
///
/// ⚠️ **返回值用 JSON 形态**：`java.ajax` 要返回字符串、`source.getLoginInfoMap` 要返回对象、
/// `book.getVariable` 要返回字符串 ⇒ 统一成 `JSONValue`。
public protocol JSHostAPIProvider: Sendable {
    /// 取一个宿主对象（`source` / `book` / `chapter` / `cookie` / `cache`）
    func hostObject(named name: String) -> HostObject?
    /// 调 `java.*` 的方法
    func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue?
}

/// **JS 作用域构造器** —— 把引擎上下文编译成**一段 JS 源码**。
///
/// ⭐ **这一步是平台无关的** ⇒ JSC 与 Node 两个执行器**共用同一份 scope 源码**
/// ⇒ 就可以**逐字对拍**（JSC vs Node）⇒ 「JSC 行为对不对」有了可验证的口径。
public enum JSScopeBuilder {

    /// 构造 scope 源码（**只含变量与宿主对象**；宿主方法由执行器注入）
    ///
    /// - Parameter ctx: 求值上下文
    /// - Returns: 一段 JS 源码，形如
    ///   ```
    ///   var result = <json>;
    ///   var baseUrl = "https://…";
    ///   var key = "";
    ///   var page = 1;
    ///   var __book = <json>;
    ///   ```
    public static func build(_ ctx: JSRunContext) -> String {
        var lines: [String] = []
        lines.append("var result = \(jsonLiteral(Self.toJSON(ctx.base.resultValue)));")
        lines.append("var baseUrl = \(jsonLiteral(.string(ctx.baseUrl)));")
        lines.append("var key = \(jsonLiteral(.string(ctx.key)));")
        lines.append("var page = \(jsonLiteral(.int(ctx.page)));")
        // 源级变量（站方 jsLib 常读 `source.getVariable()`，但也常直接用 `variables`）
        if !ctx.vars.isEmpty {
            lines.append("var variables = \(jsonLiteral(.object(ctx.vars.mapValues { .string($0) })));")
        }
        return lines.joined(separator: "\n")
    }

    /// **求值形态**：把站方代码包成函数 + **取完成值**。
    ///
    /// ⭐ 这是**站方 JS 能不能出值的要害**：
    /// 站方代码是**末行表达式**风格（不是顶层 `return`）⇒ 直接 eval 成 Script 时
    /// 拿不到「完成值」⇒ 必须包成函数体并**追加一句 return**。
    ///
    /// ⭐ 取的是**站方代码的完成值**（末行表达式的值）——
    /// ⚠️ **不要**改成「取 `result`」：页面级基准下 `result` = 页原文
    /// ⇒ 站方代码算出来的值会被**页原文盖掉** ⇒ `1 + 2` 会得到整页 HTML ⇒ 静默出错。
    ///
    /// ⚠️ **顶层 `return` 也要兜住**：站方偶尔写顶层 `return` ⇒ 直接 eval 是 Script ⇒ 语法错
    /// ⇒ 这里包成函数体 ⇒ 顶层 `return` 就合法了。
    public static func program(_ code: String) -> String {
        // ⭐⭐ **不要包成函数**！
        //
        // ⚠️ `(function(){ 1 + 2 })()` ⇒ **返回 undefined**（函数体要显式 return）
        //    而 `eval("1 + 2")` ⇒ 完成值 = **3**（Script 的完成值）
        //
        // ⇒ 站方要的就是 **Script 的完成值**（末行表达式的值）⇒ 直接拼接即可。
        //    ⭐ 站方自己给 `result` 赋值的情况也**天然正确**：
        //    `result = String(...)` 作为末行 ⇒ 赋值表达式的值 = 赋的值 ✔
        //    （大灰狼的 `ruleContent.content` 正是这么写的）
        //
        // ⚠️ 代价：**顶层 `return` 会语法错**（Script 不允许）
        //    ⇒ 但 Legado/Rhino 也是 `eval` ⇒ **两端行为一致** ✔
        //    ⇒ 站方规范本来就要求「末行表达式，别写顶层 return」。
        code
    }

    /// 旧名（等价 `program`）
    public static func wrap(_ code: String) -> String { program(code) }

    /// ⭐ **宿主 API 的 JS 包装函数**（平台无关 ⇒ JSC 与 Node 共用）
    ///
    /// 生成的形状（每个契约 API 一条）：
    /// ```js
    /// source.getVariable = function(a,b){ var r = __hostJSON('source','getVariable',JSON.stringify([a,b])); try { return JSON.parse(r); } catch(e) { return undefined; } };
    /// ```
    /// ⇒ 站方拿到的是**原类型**（字符串/数字/对象/数组），不是 JSON 文本。
    ///
    /// ⚠️ **为什么要绕这一圈**：ObjC block **桥接不了 Swift 数组/对象**
    /// ⇒ 直接把 block 注入 JSC 会在真机上炸「TypeError: Cannot convert primitive value」
    /// ⇒ 只能走「**全是 String 的 JSON 通道**」。
    public static func hostWrappers() -> [String] {
        var out: [String] = []
        for e in JSHostAPI.all where e.kind == .method {
            let obj = e.object
            let name = e.name
            let params = (0..<4).map { "a\($0)" }.joined(separator: ",")
            // ⭐⭐⭐ **宿主没实现 ⇒ 抛 TypeError**（**老引擎语义**，2026-10-24 真机「大灰狼简介/正文不一样」实证）
            //   老引擎的 `java` 对象**只有它实现的那几个方法** ⇒ 站方 `java.qread()` 会 **TypeError**
            //   ⇒ 站方用 try/catch 探测平台（`checkEnv()`：轻阅读/改版/苹果/安卓）⇒ 分支才对 ⭐
            //   以前这里返回 **undefined**（**不抛**）⇒ 站方以为「有这个能力」⇒ **走错分支** ⭐⭐⭐
            //   （🍅大灰狼：简介差 27 字、正文差 13 字 ⇒ 就是这一条）
            out.append("""
            try { \(obj).\(name) = function(\(params)){ \
              var __r = JSON.parse(__hostJSON('\(obj)','\(name)',JSON.stringify([\(params)]))); \
              if (__r && __r.__qrNotImplemented) { throw new TypeError('\(obj).\(name) is not a function'); } \
              return (__r && __r.length !== undefined) ? __r[0] : undefined; \
            }; } catch(e) {}
            """)
        }
        return out
    }

    /// RuleValue → JSONValue（**站方 JS 要的是 JSON 视图**）
    ///
    /// ⭐ 条目级基准 ⇒ `result` 是**那个对象**（§S-RES-01）⇒ 站方能读 `result.book_id`
    /// ⇒ 节点 ⇒ `{全部属性 + "_text": 文本}`
    public static func toJSON(_ r: RuleValue) -> JSONValue {
        // ⭐ 口径统一到核心层（`RuleValue.jsonValue`）⇒ 免得两处转换慢慢长歪
        r.jsonValue
    }

    /// JSON 值 → JS 字面量
    public static func jsonLiteral(_ v: JSONValue) -> String {
        switch v {
        case .null:      return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i):  return String(i)
        case .double(let d): return RuleValue.numberToString(d)
        case .string(let s): return "\"\(escape(s))\""
        case .array(let a): return "[" + a.map { jsonLiteral($0) }.joined(separator: ",") + "]"
        case .object(let o):
            let parts = o.map { "\"\(escape($0.key))\":\(jsonLiteral($0.value))" }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out
    }
}
