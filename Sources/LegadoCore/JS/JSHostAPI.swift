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

        // ⭐⭐⭐ **2026-10-25 补齐：老引擎上存在、但契约漏登记的 39 个**
        //   ⇒ 老引擎 java 对象上**有**这些方法（宿主 op 缺失时只 resolve {ok:false} ⇒ **不抛**）
        //   ⇒ 契约漏 = JS 侧**不生成包装函数** ⇒ 站方 `java.xxx()` 报 **TypeError**
        //   ⇒ 而老引擎上**不抛** ⇒ 新引擎抛 = **回归**（站方 JS 第一句就炸 ⇒ 整条规则死定）⭐⭐⭐
        //   （名单实测来源：conformance/fixtures/legacy-java-nothrow.json）
        .init(object: "java", name: "ajaxAsync", kind: .method), .init(object: "java", name: "ajaxPromise", kind: .method), .init(object: "java", name: "base64DecodeToByteArray", kind: .method),
        .init(object: "java", name: "cacheFile", kind: .method), .init(object: "java", name: "cacheText", kind: .method), .init(object: "java", name: "clear", kind: .method),
        .init(object: "java", name: "connectAsync", kind: .method), .init(object: "java", name: "containsKey", kind: .method), .init(object: "java", name: "del", kind: .method),
        .init(object: "java", name: "delete", kind: .method), .init(object: "java", name: "encodeURI", kind: .method), .init(object: "java", name: "encodeURIComponent", kind: .method),
        .init(object: "java", name: "escape", kind: .method), .init(object: "java", name: "getAsync", kind: .method), .init(object: "java", name: "getFloat", kind: .method),
        .init(object: "java", name: "getInt", kind: .method), .init(object: "java", name: "getLang", kind: .method), .init(object: "java", name: "getList", kind: .method),
        .init(object: "java", name: "getObject", kind: .method), .init(object: "java", name: "getPromise", kind: .method), .init(object: "java", name: "getStrResponse", kind: .method),
        .init(object: "java", name: "getStringArray", kind: .method), .init(object: "java", name: "getStringMatch", kind: .method), .init(object: "java", name: "getStringWrapper", kind: .method),
        .init(object: "java", name: "head", kind: .method), .init(object: "java", name: "htmlFormat", kind: .method), .init(object: "java", name: "importScript", kind: .method),
        .init(object: "java", name: "isWhiteList", kind: .method), .init(object: "java", name: "md5Encode16", kind: .method), .init(object: "java", name: "openBrowser", kind: .method),
        .init(object: "java", name: "postAsync", kind: .method), .init(object: "java", name: "postPromise", kind: .method), .init(object: "java", name: "readFile", kind: .method),
        .init(object: "java", name: "regex", kind: .method), .init(object: "java", name: "removeCookie", kind: .method), .init(object: "java", name: "setCookie", kind: .method),
        .init(object: "java", name: "sha1Encode", kind: .method), .init(object: "java", name: "toString", kind: .method), .init(object: "java", name: "unescape", kind: .method),

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
        // ⭐⭐⭐ **source.get / source.put**（读/写「书籍变量」的某一项）
        //   —— 老引擎 `source-api.js` 有，自研引擎的 `makeSourceObject` **也实现了**，
        //   但契约里**漏登记** ⇒ 包装函数不生成 ⇒ 站方 `source.get("k")` 直接
        //   **TypeError: not a function** ⇒ 站方 try/catch 吞掉 ⇒ **静默失效** ⭐⭐⭐
        //   （125 源实测：**71 处 get + 58 处 put** ⇒ 命中就是整源空白/假成功）
        .init(object: "source", name: "get", kind: .method),
        .init(object: "source", name: "put", kind: .method),

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
        // ⭐ `cookie.replaceCookie`（引擎已实现，契约漏登记 ⇒ 站方调用 TypeError）
        .init(object: "cookie", name: "replaceCookie", kind: .method),

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

    /// ⭐⭐⭐ **老引擎上「调用不抛异常」的 API**（**自动生成**，勿手改）
    ///
    /// 源：`conformance/fixtures/legacy-java-nothrow.json`
    /// ⇒ 由 `tools/probe_legacy_java_nothrow.js`（**真跑老引擎** + 忠实宿主 mock）实测得出
    /// ⇒ 再由 `tools/gen_legacy_nothrow.py` 写进本文件 ⭐⭐⭐
    ///
    /// ⚠️ **为什么要有它**（2026-10-25 真机：`java.longToast is not a function`）：
    ///   宿主没实现 ⇒ 包装函数抛 TypeError ⇒ **站方 JS 第一句就炸** ⇒ 整条规则死定 ⭐⭐⭐
    ///   ⇒ **但「抛不抛」不能一刀切**：
    ///     · 老引擎上**压根没有**这个方法 ⇒ 站方 `try/catch` 探测平台 ⇒ **必须抛**（抛了站方才走对分支）⭐
    ///     · 老引擎上**有**这个方法（宿主 op 缺失时 `nativeCall` 只 resolve `{ok:false}` ⇒ **不抛**）
    ///       ⇒ 新引擎也**不许抛** ⇒ 否则站方脚本直接死 = **回归** ⭐⭐⭐
    ///   ⇒ 名单内的：**宿主没实现 ⇒ 静默返回 undefined**（与老引擎一致）
    ///   ⇒ 名单外的：**照旧抛 TypeError**（与老引擎一致）
    public static let legacyPresentKeys: Set<String> = [
"java.ajax", "java.ajaxAsync", "java.ajaxPromise", "java.androidId", "java.base64Decode",
"java.base64DecodeToByteArray", "java.base64Encode", "java.cacheFile", "java.cacheText", "java.clear",
"java.connect", "java.connectAsync", "java.containsKey", "java.createSymmetricCrypto", "java.del",
"java.delete", "java.deviceID", "java.encodeURI", "java.encodeURIComponent", "java.escape", "java.get",
"java.getAbsoluteURL", "java.getAsync", "java.getCookie", "java.getElement", "java.getElements",
"java.getFloat", "java.getInt", "java.getLang", "java.getList", "java.getObject", "java.getPromise",
"java.getStrResponse", "java.getString", "java.getStringArray", "java.getStringMatch",
"java.getStringWrapper", "java.getWebViewUA", "java.head", "java.hexDecodeToString", "java.htmlFormat",
"java.importScript", "java.isWhiteList", "java.log", "java.longToast", "java.md5Encode",
"java.md5Encode16", "java.openBrowser", "java.post", "java.postAsync", "java.postPromise", "java.put",
"java.randomUUID", "java.reLoginView", "java.readFile", "java.refreshExplore", "java.refreshTocUrl",
"java.regex", "java.removeCookie", "java.searchBook", "java.setContent", "java.setCookie",
"java.sha1Encode", "java.showBrowser", "java.showReadingBrowser", "java.startBrowser",
"java.startBrowserAwait", "java.startBrowserDp", "java.t2s", "java.timeFormat", "java.timeFormatUTC",
"java.toNumChapter", "java.toString", "java.toast", "java.unescape"
    ]

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
    /// ⭐⭐⭐⭐⭐ **把 jsLib 的顶层声明显式挂到 `globalThis`**（2026-10-26 真机回归实证）
    ///
    /// ⚠️ **为什么**：`evaluateScript` 的顶层 `var`/`function` **不进全局**（JSC ≠ WebKit）
    ///   ⇒ 站方 jsLib 定义的 `hjmDec` 等函数在**规则求值时可能看不见**
    ///   ⇒ 站方 `catch(e){return []}` 吞掉 ⇒ **0 本书**（真机症状）⭐⭐⭐
    ///
    /// ⭐⭐⭐ **做法**：扫出顶层符号 ⇒ 在**同一段脚本末尾**追加 `globalThis.X = X`
    ///   ⇒ 同一段代码 = 同一作用域 ⇒ **一定可见** ⇒ 不依赖 eval 语义 ⭐⭐⭐
    public static func withExplicitGlobalExport(_ code: String) -> String {
        let names = topLevelDeclaredNames(code)
        guard !names.isEmpty else { return code }
        var out = code
        // ⭐⭐⭐⭐⭐ **用 `this` 而不是 `globalThis`**（2026-10-26 真机回归实证）
        //
        // ⚠️⚠️ **为什么**：`currentGlobals(in:)` 抓全局用的是 **`Object.getOwnPropertyNames(this)`**
        //   ⇒ 它认的是 **`this`** 指向的那个对象
        //   ⇒ 而导出若写 `globalThis.X = X` ⇒ **两者可能不是同一个对象** ⇒
        //     ⇒ 导出的符号**不在基线里** ⇒ 每次求值前的全局治理把它**置 undefined** ⭐⭐⭐
        //     ⇒ ⇒ 站方 jsLib 的 `hjmDec` 不可见 ⇒ **0 本书** ⭐⭐⭐
        //
        // ⭐ **正解**：**优先用 `this`**（与 `currentGlobals` 逐字一致）⇒ `globalThis` 只做兜底
        out += "\n;try{var __qrG=(this&&typeof this==='object')?this:(typeof globalThis!=='undefined'?globalThis:null);"
        for n in names {
            out += "if(__qrG&&typeof \(n)!=='undefined'&&__qrG.\(n)===undefined){__qrG.\(n)=\(n);}"
        }
        out += "}catch(e){}"
        return out
    }

    /// ⭐⭐⭐ **扫出 JS 源码的顶层声明名**（`var X` / `let X` / `const X` / `function X`）
    ///
    /// ⚠️ **只扫顶层**（行首缩进 0）⇒ 避免把**函数体内的局部变量**也导出
    ///   （导出了会污染全局 ⇒ 别的源会读到 ⇒ 串源）⭐⭐⭐
    public static func topLevelDeclaredNames(_ code: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for rawLine in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // ⭐⭐⭐ **只看顶格**（不以空白开头）⇒ 排除函数体内的局部声明
            guard let first = line.first, !first.isWhitespace else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") { continue }
            // ① `var X =` / `let X =` / `const X =`
            var name = firstCapture(trimmed, #"^(?:var|let|const)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#)
            // ② `function X(` / `async function X(`
            if name == nil {
                name = firstCapture(trimmed, #"^(?:async\s+)?function\s+([A-Za-z_$][A-Za-z0-9_$]*)"#)
            }
            if let n = name, !n.isEmpty, !seen.contains(n) {
                seen.insert(n)
                names.append(n)
            }
        }
        return names
    }

    /// ⭐⭐⭐ **取正则的第 1 个捕获组**
    public static func firstCapture(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }



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
        // ⭐⭐⭐ **消息收集**（登录链路用）—— 老引擎的 `QR.__qrMsgSink` 同款
        //   站方**只**用 `java.toast` / `java.log` 报登录结果 ⇒ 这段原文是唯一依据 ⭐⭐⭐
        //   ⚠️ 收集器必须是**局部 var**（`var` 在 eval 里是脚本作用域）
        //   ⇒ 读的时候要**同一次 eval** 里取（分两次 eval 拿不到）⭐
        // ⭐⭐⭐ **额外变量**（老引擎 `makeScope({ infoMap: … })` 同款）
        //   ⇒ 发现页筛选栏的 action 靠它读 `infoMap['平台']` ⭐⭐⭐
        for (k, v) in ctx.extra {
            lines.append("var \(k) = \(jsonLiteral(v));")
        }
        // ⭐⭐⭐⭐⭐ **内部变量（`__qr` 前缀）要同时挂到【全局】** ⭐⭐⭐⭐⭐
        //
        // ⚠️⚠️ **为什么**（2026-10-25 迁移门禁时实证）：
        //   · 宿主对象的实现（`source.getLoginInfoMap()` 等）是**全局函数**
        //     ⇒ 它们**看不到** eval 作用域里的局部 `var` ⇒ 读不到引擎刚合并好的登录信息⭐⭐⭐
        //   · 登录链路的语义 = 「点 action 时先把输入框的值合并进登录信息，**再**执行 action」
        //     ⇒ 站方在 action 里读 `getLoginInfoMap()` 必须读到**合并之后**那份⭐⭐⭐
        //   ⇒ 所以：引擎把合并后的登录信息放进 `extra["__qrLoginInfo"]`
        //     ⇒ 这里挂到全局 ⇒ 宿主对象的实现读得到 ⭐⭐⭐
        //   ⇒ （跟 `__qrMsgSink` 同一个道理：**全局的才是宿主能摸到的**）⭐
        for (k, _) in ctx.extra where k.hasPrefix("__qr") {
            lines.append("try { globalThis.\(k) = \(k); } catch(e) {}")
        }
        if ctx.collectMessages {
            lines.append("var __qrMsgs = []; var __qrMsgSink = function(m){ __qrMsgs.push(String(m == null ? '' : m)); };")
            // ⭐⭐⭐ **收集器必须挂到全局**（`globalThis.__qrMsgSink`）⭐⭐⭐
            //
            // ⚠️⚠️ **为什么**（2026-10-25 迁移门禁时实证）：
            //   宿主包装函数（`java.toast` / `java.log`）是**全局函数**（context 创建时注入）
            //   ⇒ 它**看不到** eval 作用域里的局部 `var __qrMsgSink` ⇒ 站方原文永远收不到
            //   ⇒ 后果：`runLoginAction` / `probeLoginStatus` 的 `messages` **恒为空**
            //   ⇒ 登录面板拿不到站方原文（「登录成功 / 失败」无从判断）⭐⭐⭐
            //   ⇒ 老引擎的 `QR.__qrMsgSink` 就是**全局属性** ⇒ 这里照抄（语义等价）⭐
            lines.append("try { globalThis.__qrMsgSink = __qrMsgSink; } catch(e) {}")
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
        // ⭐⭐⭐⭐⭐ **顶层 `return` 要支持**（2026-10-25 真机实证，通用真凶）
        //
        // ⚠️⚠️⚠️ **以前的注释说「不支持顶层 return，两端行为一致」⇒ 是错的**：
        // · **站方真的写顶层 `return`**（🍅大灰狼的 `ruleBookInfo.tocUrl` 就是）
        //   ⇒ `@js: var b = …; return "data:;base64,…";` ⇒ **语法错** ⇒ 规则失败 ⭐⭐⭐
        // · 而 Legado/Rhino 的 `eval` **允许**顶层 return（Rhino 的 eval 是函数作用域）⭐⭐⭐
        //   ⇒ ⇒ **引擎才是那个「不一致」的一方** ⇒ 必须在引擎侧补上 ⭐⭐⭐
        //
        // ⭐ **怎么同时支持两种形态**：
        //   ① 包成函数体 ⇒ **顶层 return 合法**（`return` 直接返回）
        //   ② 但函数体**没有 return 时**返回 undefined ⇒ **末行表达式的值丢了**（不合 Legado 语义）⭐⭐⭐
        // ⇒ 解法：**先试「包成函数」；若结果不是 undefined ⇒ 用它；
        //   否则回退到「末行表达式」形态**（两个都跑 ⇒ 慢一点，但语义全对）⭐⭐⭐
        //
        // ⭐ 或者更省：**用 `eval` 在函数体里跑**，函数体末尾追加 `return <末行表达式>`：
        //   ⇒ 顶层 return 仍是语法错（因为 eval 的是 Script）⇒ 不行 ⭐⭐⭐
        // ⇒ 所以用「两次求值」方案（见 `programPair`）⭐⭐⭐
        programPair(code).asScript
    }

    /// ⭐⭐⭐⭐⭐ **两种求值形态**（给求值器挑）
    ///
    /// - `asFunction`: 包成函数体 ⇒ **顶层 `return` 合法** ⇒ 返回值优先用
    /// - `asScript`:  原样 Script ⇒ **末行表达式的完成值**（Legado 的主语义）⇒ 兜底
    ///
    /// ⭐⭐⭐ **为什么两个都要**（2026-10-25 真机实证）：
    /// · 站方**真的**写顶层 `return`（🍅大灰狼的 `ruleBookInfo.tocUrl` 就是）
    ///   ⇒ 只用 Script 形态 ⇒ **语法错** ⇒ 规则失败 ⭐⭐⭐
    /// · 而站方也大量写「末行表达式」（没有 return）⇒ 只用函数体形态 ⇒ **拿到 undefined** ⭐⭐⭐
    /// ⇒ ⇒ **两个都跑**：函数体版有值用它，否则用 Script 版 ⭐⭐⭐
    public static func programPair(_ code: String) -> (asFunction: String, asScript: String) {
        // ① 包成函数体（`return` 合法）
        let asFunction = "(function(){\n" + code + "\n})()"
        // ② 原样 Script（末行表达式的完成值）
        let asScript = code
        return (asFunction, asScript)
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
            // ⭐⭐⭐ **「宿主没实现」要不要抛 TypeError？——由「老引擎上存不存在」决定**（2026-10-25 真机实证）
            //
            //   ① **老引擎上压根没这个方法**（`java.qread` / `java.copyText` / `java.digestHex`）
            //      ⇒ 站方 `try/catch` 探测平台（`checkEnv()`：轻阅读/改版/苹果/安卓）⇒ **必须抛**
            //      ⇒ 抛了站方才走对分支；以前这里返回 undefined（**不抛**）⇒ 站方以为「有这个能力」
            //      ⇒ **走错分支**（🍅大灰狼：简介差 27 字、正文差 13 字 ⇒ 就是这一条）⭐⭐⭐
            //
            //   ② **老引擎上有这个方法**（宿主 op 缺失时 `nativeCall` 只 resolve `{ok:false}` ⇒ **不抛**）
            //      ⇒ 新引擎也**不许抛** ⇒ 否则 **站方 JS 第一句就炸** ⇒ 整条规则死定 ⭐⭐⭐
            //      （真机实证：`java.longToast is not a function` ⇒ 站方 125 源 **114 处**在用）
            //
            //   ⇒ 名单 = 「老引擎上调用**不抛异常**」的方法（**实测**得出，见 legacyPresentKeys 的注释）⭐
            let throwsWhenUnimplemented = !JSHostAPI.legacyPresentKeys.contains(e.key)
            // ⚠️⚠️⚠️ **注释必须单独一行**：`//` 是**行注释** ⇒ 写在语句后面会把**下一行也吃掉**
            //   ⇒ 生成的 JS 语法坏 ⇒ **整段 hostWrappers 注入失败** ⇒ 所有 java.* 方法全没了
            //   ⇒ 症状：站方 `java.xxx is not a function`（不是引擎抛的，是 JSC 说属性不存在）⭐⭐⭐
            //   （2026-10-25 build248 真机事故：这一行注释把 return 吃掉 ⇒ 整段挂）
            let guardClause: String
            if throwsWhenUnimplemented {
                guardClause = "if (__r && __r.__qrNotImplemented) { throw new TypeError('\(obj).\(name) is not a function'); }"
            } else {
                // ⭐ 老引擎上不抛 ⇒ 新引擎也不抛（静默返回 undefined）
                guardClause = "if (__r && __r.__qrNotImplemented) { return undefined; }"
            }
            // ⭐⭐⭐⭐⭐ **站方原文的收集**（老引擎 `pushMsg` 同款）⭐⭐⭐⭐⭐
            //
            // ⚠️⚠️ **为什么必须有**（2026-10-25 迁移门禁时实证）：
            //   站方书源**只**用 `java.toast` / `java.longToast` / `java.log` 报登录结果
            //   （"✅️登录成功" / "💔登录失败" / 会员卡片）
            //   ⇒ 这段原文是**判断「登录成没成功」的唯一依据**⭐⭐⭐
            //   ⇒ 老引擎的 `java-api.js` 里 `toast/log` 都先 `pushMsg(s, kind)`
            //   ⇒ `pushMsg` 把原文塞进**全局的** `QR.__qrMsgSink` ⇒ 这里照抄：塞进全局的
            //     `globalThis.__qrMsgSink`（收集器由 `JSScopeBuilder.build` 挂在全局）⭐
            //
            // ⚠️ **顺序**：先收集**再**交给宿主 ⇒ 宿主弹 toast 的同时原文已经拿到了 ⭐
            let sinkPush: String
            if obj == "java" && ["toast", "longToast", "log"].contains(name) {
                sinkPush = "try { if (typeof globalThis !== 'undefined' && typeof globalThis.__qrMsgSink === 'function') { globalThis.__qrMsgSink(a0); } } catch(e) {} "
            } else {
                sinkPush = ""
            }
            out.append("""
            try { \(obj).\(name) = function(\(params)){ \
              \(sinkPush)\
              var __r = JSON.parse(__hostJSON('\(obj)','\(name)',JSON.stringify([\(params)]))); \
              \(guardClause) \
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
