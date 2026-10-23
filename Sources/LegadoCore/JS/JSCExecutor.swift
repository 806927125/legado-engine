import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore

/// **JSC 执行器**（JavaScriptCore）—— 站方 JS 的**生产实现**。
///
/// ⚠️ **只能在 Apple 平台编译** ⇒ Linux 沙盒验不了 ⇒
/// ① 沙盒用 `swiftc -parse` 查**语法**
/// ② **行为**靠 macOS CI 验
///
/// ⭐⭐ **API 兼容策略：只依赖最基础的三个 API**
/// （`evaluateScript` / `setObject(_:forKeyedSubscript:)` / `setObject(_:at:)`）——
/// ⚠️ 因为 **Xcode 26 的 JavaScriptCore 换成了 Swift-native 实现**，
/// `JSValue.newObject` / `newArray` / `nullIn` 这些**静态工厂方法全没了**。
/// ⇒ 一律用 `evaluateScript` 现场造对象/数组/字面量 ⇒ 不吃版本差异。
///
/// ⭐ **求值形态是这里最关键的一件事**（§S-JS-09）：
/// 站方 JS 是**末行表达式**风格（不是顶层 `return`）⇒ 直接 `evaluateScript` 就能拿到
/// **Script 的完成值**（末行表达式的值）⇒ **不要包成函数体**
/// （`(function(){ 1 + 2 })()` 返回 undefined！——函数体要显式 return）
public final class JSCExecutor: JSExecutor {

    /// 宿主 API 提供者（`java.*` 与宿主对象的实现）
    private let api: JSHostAPIProvider

    /// ⭐⭐ **引擎侧接管的 `java.*`**（可选）—— 宿主不用实现引擎能做的那些
    private var engineAPI: JSEngineAPIHandler?

    // MARK: - ⭐⭐ 上下文复用（性能）

    /// ⭐⭐ **复用的 `JSContext`** —— 实测「每次新建」**1.018 ms/次**
    ///   vs「复用」**0.003 ms/次** ⇒ **省 340×**（macOS CI 实测，见 JSCPerfTests）
    private var cachedContext: JavaScriptCore.JSContext?

    /// 宿主通道 / 包装函数**是否已注入**（契约不变 ⇒ 只注入一次）
    private var hostChannelReady = false

    /// ⭐ **基线全局快照**（注入完宿主通道后的全局名集合）
    /// ⇒ 每次跑之前把「**相对基线新增的**」全删掉 ⇒ 站方 jsLib 的全局不会串源 ⭐
    private var baselineGlobals: Set<String> = []

    /// ⭐ **JSContext 不是线程安全的** ⇒ 整个 `run` 加锁（引擎全同步 ⇒ 本来就是串的）
    private let contextLock = NSLock()

    public init(api: JSHostAPIProvider) {
        self.api = api
    }

    /// ⭐⭐ 让引擎接管 `java.*`（`ajax` / `md5Encode` / `base64*` / …）
    public func setEngineAPI(_ handler: JSEngineAPIHandler?) {
        self.engineAPI = handler
    }

    /// ⭐⭐⭐ **作废当前 context**（下次 `run` 重建一个干净的）
    ///
    /// ⚠️ **什么时候必须调**：**站方书源的 jsLib 跑完之后**
    ///   （jsLib 定义的是全局 `var host` / `function getArguments` ⇒ 污染 context）
    /// ⇒ 宿主在「加载书源 jsLib」前后调一次 ⇒ 彻底隔离 ⭐
    ///
    /// ⚠️ **为什么不能只靠「每次跑前清全局」**：
    /// 全局 `var` 的属性 **configurable = false** ⇒ **`delete` 删不掉**
    /// ⇒ 只能「赋值成 undefined」⇒ 属性还在（`"x" in globalThis` 仍 true）⭐
    /// ⇒ ⇒ **彻底干净只能重建 context**
    /// ⭐⭐⭐ **把当前全局标为基线**（站方 `loginUrl` 加载后调 ⇒ 它的全局被保留）
    public func markGlobalsAsBaseline() {
        contextLock.lock()
        defer { contextLock.unlock() }
        guard let js = cachedContext else { return }
        baselineGlobals = Self.currentGlobals(in: js)
    }

    public func invalidate() {
        contextLock.lock()
        defer { contextLock.unlock() }
        cachedContext = nil
        hostChannelReady = false
        baselineGlobals = []
    }

    public func run(_ code: String, context: JSRunContext) throws -> JSONValue {
        // ⭐⭐ **上下文复用** ⇒ 整个 run 加锁（JSContext 非线程安全）
        contextLock.lock()
        defer { contextLock.unlock() }

        // ① 拿（首次则建）**可复用**的 context
        let js: JavaScriptCore.JSContext
        if let cached = cachedContext {
            js = cached
        } else {
            guard let created = JavaScriptCore.JSContext() else {
                throw JSCError.contextUnavailable
            }
            cachedContext = created
            js = created
        }
        // ⚠️ Swift 的 block **不能抛错** ⇒ 异常处理器只**记录**
        //    （macOS 上编译不过的元凶之一）
        final class Box: @unchecked Sendable { var value: String? }
        let caught = Box()
        js.exceptionHandler = { (ctx: JavaScriptCore.JSContext?, exception: JSValue?) in
            if let exception { caught.value = String(describing: exception) }
        }

        // ① 注入宿主通道
        //
        // ⭐⭐ **ObjC block 桥接不了 Swift 数组/对象** ⇒
        //   `@convention(block) ([JSValue]) -> JSValue?` 在真机上会报
        //   「TypeError: Cannot convert primitive value」。
        //
        // ⇒ 改走 **JSON 字符串通道**（只用 String，ObjC 一定能桥接）：
        //   JS 侧：包函数把参数 JSON 化 ⇒ 调 `__hostJSON(obj, method, argsJSON)`
        //   Swift 侧：解析 args ⇒ 调宿主 ⇒ 结果 JSON 化回字符串
        //   JS 侧再 `JSON.parse` 还原 ⇒ 站方拿到原类型
        // ①' ⭐⭐ **宿主通道只注入一次**（契约不变 ⇒ 包装函数不用重生成）
        if !hostChannelReady {
            if let hostBlock = makeHostBlock(in: js, base: context.base) {
                js.setObject(unsafeBitCast(hostBlock, to: AnyObject.self),
                              forKeyedSubscript: "__hostJSON" as NSString)
            }
            // ② 先把宿主对象**建出来**（包装函数要往它们身上挂）
            _ = js.evaluateScript("var source={},book={},chapter={},cookie={},cache={},java={};")

            // ③ 注入**属性**（属性不是函数 ⇒ 直接 setObject，不走 block）
            for name in JSHostAPI.objects {
                guard let obj = api.hostObject(named: name) else { continue }
                // ⚠️ `forKeyedSubscript` **不支持 "a.b" 路径** ⇒ 要先拿到那个对象再设属性
                guard let hostObj = js.objectForKeyedSubscript(name as NSString) else { continue }
                for (prop, value) in obj.properties {
                    if let jv = Self.toJS(value, in: js) {
                        hostObj.setObject(jv, forKeyedSubscript: prop as NSString)
                    }
                }
            }

            // ④ 为契约里的每个**方法**生成 JS 包装函数
            for src in JSScopeBuilder.hostWrappers() {
                _ = js.evaluateScript(src)
            }
            // ⭐ **基线快照**（注入完之后）⇒ 之后每次跑清掉「相对它新增的」全局
            baselineGlobals = Self.currentGlobals(in: js)
            hostChannelReady = true
        } else {
            // ⭐⭐ **清理站方残留的全局**（复用 context 的代价 ⇒ 必须治）
            //   站方 jsLib 定义的 `var host` / `function getArguments` 会留在全局
            //   ⇒ 下条规则/下个源会被污染（轻阅踩过这个坑）⭐
            Self.removeGlobals(notIn: baselineGlobals, in: js)
        }

        // ⑤ 求值（scope 变量 + 站方代码 ⇒ 完成值）
        let source = JSScopeBuilder.build(context) + "\n" + JSScopeBuilder.program(code)
        let value = js.evaluateScript(source)
        // ⭐ 站方 JS 抛异常 ⇒ 必须**报出来**（不能静默空）
        if let msg = caught.value {
            throw JSCError.scriptException(msg)
        }
        guard let value else { return .null }
        return Self.toJSON(value)
    }

    // MARK: - 宿主对象 → JS 对象

    /// 把 `HostObject`（方法 + 属性）转成 JS 对象
    private static func makeObject(_ obj: HostObject, in js: JavaScriptCore.JSContext) -> JSValue? {
        guard let out = js.evaluateScript("({})") else { return nil }
        // 方法
        for (name, _) in obj.methods {
            let host = obj
            // ⚠️ JSC 的 block 约定：返回 `JSValue!`；且 Swift 闭包**不能直接当 `Any!` 传**
            //    ⇒ 必须 `unsafeBitCast` 成 ObjC block（macOS 上编译不过的元凶之二）
            // ⚠️ 返回 `JSValue?`（不是 `JSValue!`）—— Swift 6.2+ 不允许对 IUO 用 `!`
            let block: @convention(block) ([JSValue]) -> JSValue? = { args in
                let jsonArgs = args.map { Self.toJSON($0) }
                guard let r = host.call(name, jsonArgs),
                      let jv = Self.toJS(r, in: js) else {
                    return js.evaluateScript("undefined")
                }
                return jv
            }
            out.setObject(unsafeBitCast(block, to: AnyObject.self),
                          forKeyedSubscript: name as NSString)
        }
        // 属性
        for (name, v) in obj.properties {
            if let jv = Self.toJS(v, in: js) {
                out.setObject(jv, forKeyedSubscript: name as NSString)
            }
        }
        return out
    }

    /// `java.*` ⇒ 一个 JS 对象（方法都转到宿主）
    private func makeJavaObject(in js: JavaScriptCore.JSContext) -> JSValue? {
        guard let out = js.evaluateScript("({})") else { return nil }
        let provider = self.api
        for entry in JSHostAPI.methods where entry.object == "java" {
            let name = entry.name
            // ⚠️ 返回 `JSValue?`（不是 `JSValue!`）—— Swift 6.2+ 不允许对 IUO 用 `!`
            let block: @convention(block) ([JSValue]) -> JSValue? = { args in
                let jsonArgs = args.map { Self.toJSON($0) }
                guard let r = provider.callJava(name, jsonArgs),
                      let jv = Self.toJS(r, in: js) else {
                    return js.evaluateScript("undefined")
                }
                return jv
            }
            out.setObject(unsafeBitCast(block, to: AnyObject.self),
                          forKeyedSubscript: name as NSString)
        }
        return out
    }


    // MARK: - 宿主通道

    /// `__hostJSON(object, method, argsJSON)` ⇒ 结果的 JSON 文本
    ///
    /// ⚠️ **只用 String 参数/返回** ⇒ ObjC block 一定能桥接
    /// （Swift 数组/对象在 block 里会被 JSC 拒 ⇒ "Cannot convert primitive value"）
    private func makeHostBlock(in js: JavaScriptCore.JSContext, base: RuleBase)
        -> (@convention(block) (String, String, String) -> String)? {
        let provider = self.api
        // ⭐⭐ **当前基准** —— `java.getString('$.x')` 的 JSONPath 要对基准求值
        //    ⚠️ block 只收 `object/method/argsJSON` ⇒ 基准得**捕获进来**（不能引用 context）
        let currentBase = base
        // ⭐⭐ **引擎侧优先接管 `java.*`**（宿主不用实现引擎能做的那些）
        let engineAPI = self.engineAPI
        let block: @convention(block) (String, String, String) -> String = { object, method, argsJSON in
            var args: [JSONValue] = []
            if let data = argsJSON.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                args = arr.map { JSONValue.from($0) }
            }
            // ⭐⭐ **引擎侧接管**（`ajax` / `md5Encode` / `base64*` / …）
            //   ⇒ 引擎有 transport + cookie jar + 源级 header ⇒ 天然能做
            //
            // ⭐ **返回 nil = 「我不接管」** ⇒ 落回宿主实现
            //   （⇒ 引擎只抢它真做的那几个，其余仍归宿主）
            if object == "java", let engineAPI, let r = engineAPI(method, args, currentBase) {
                // ⚠️ 顶层标量不能 JSON 序列化 ⇒ 统一包一层数组（JS 侧取 `[0]`）
                let any = Self.toFoundation(r)
                guard let data = try? JSONSerialization.data(withJSONObject: [any]),
                      let text = String(data: data, encoding: .utf8) else { return "null" }
                return text
            }
            let result: JSONValue?
            if object == "java" {
                result = provider.callJava(method, args)
            } else {
                result = provider.hostObject(named: object)?.call(method, args)
            }
            guard let result else { return "null" }
            let any = Self.toFoundation(result)
            // ⚠️ `JSONSerialization` **只接受容器**（数组/字典）⇒ 顶层标量会被拒
            // ⇒ 统一**包一层数组**返回；JS 侧包装函数取 `[0]` 还原 ⇒ 不用在 Swift 侧剥（剥了又会撞标量）
            guard let data = try? JSONSerialization.data(withJSONObject: [any]),
                  let text = String(data: data, encoding: .utf8) else { return "null" }
            return text
        }
        return block
    }

    // MARK: - ⭐⭐ 全局治理（复用 context 的代价）

    /// ⭐ **枚举当前 context 的全局名**。
    ///
    /// ⚠️ **JSC 没有「列出全局」的 API** ⇒ 只能**在 JS 里枚举**
    /// ⇒ `for...in` + `hasOwnProperty` ⇒ 能拿到全局的**自有可枚举属性**
    /// ⇒ 正好就是 `var` / `function` 声明留下的那些（站方 jsLib 的污染源）⭐
    private static func currentGlobals(in js: JavaScriptCore.JSContext) -> Set<String> {
        // ⚠️⚠️ **必须用 `Object.getOwnPropertyNames`，不能用 `for...in`**
        //   ⇒ 全局代码里的 `var` 声明创建的属性是**【不可枚举】**的
        //   ⇒ `for...in` **枚举不到** ⇒ 全局清理形同虚设（门禁红出来的）⭐
        let src = """
        (function(){var o=Object.getOwnPropertyNames(this);return o.join(String.fromCharCode(1));})()
        """
        guard let v = js.evaluateScript(src) else { return [] }
        let text = v.toString() ?? ""
        guard !text.isEmpty else { return [] }
        return Set(text.components(separatedBy: "\u{1}"))
    }

    /// ⭐ **清掉不在 `keep` 里的全局**（⇒ 站方 jsLib 的全局不会串源）
    ///
    /// ⚠️⚠️⚠️ **不能用 `delete`！**（macOS CI 探针实证）
    /// ```
    /// [probe] count=76 inNames=true cfg=false,enum=true after=string
    /// ```
    /// ⇒ 全局代码里 `var` / `function` 声明创建的属性是
    /// **【configurable = false】** ⇒ **`delete` 无效**（delete 之后 `typeof` 仍是 "string"）⭐
    /// ⚠️ `for...in` 反而**能**枚举到它们（`enum=true`）⇒ 用 `Object.getOwnPropertyNames` 更保险
    ///
    /// ✅ 所以改成**赋值成 `undefined`**（属性 writable ⇒ 可赋值）
    /// ⇒ 站方 `typeof x !== 'undefined'` / `x ? … : …` 都能正常判空 ✔
    /// ⚠️ 但**属性本身还在**（`"x" in globalThis` 仍为 true）⇒
    /// ⇒ **要彻底干净得调 `invalidate()` 重建 context**（见下）⭐
    private static func removeGlobals(notIn keep: Set<String>, in js: JavaScriptCore.JSContext) {
        let extras = currentGlobals(in: js).subtracting(keep)
        guard !extras.isEmpty else { return }
        let list = extras.sorted().map { name -> String in
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        }.joined(separator: ",")
        // ⚠️ **赋值 undefined，不是 delete**（delete 对 configurable=false 无效）
        _ = js.evaluateScript("(function(){var g=this;[\(list)].forEach(function(k){try{g[k]=undefined;}catch(e){}});})()")
    }

    /// JSONValue → Foundation 值（要能过 `JSONSerialization`）
    /// ⚠️ 实现搬到核心层（`JSONValue.foundationValue`）⇒ 平台无关
    static func toFoundation(_ v: JSONValue) -> Any { v.foundationValue }

    // MARK: - 值转换

    /// JSONValue → JSValue
    ///
    /// ⭐ **一律用 `evaluateScript` 现场造** ⇒ 不依赖 `JSValue` 的静态工厂
    /// （Xcode 26 的 JSC 把那些删了）⇒ 版本兼容。
    static func toJS(_ v: JSONValue, in js: JavaScriptCore.JSContext) -> JSValue? {
        js.evaluateScript(JSScopeBuilder.jsonLiteral(v))
    }

    /// JSValue → JSONValue
    static func toJSON(_ v: JSValue) -> JSONValue {
        if v.isUndefined || v.isNull { return .null }
        if v.isBoolean { return .bool(v.toBool()) }
        if v.isNumber { return .double(v.toDouble()) }
        if v.isString { return .string(v.toString()) }
        if v.isArray {
            // ⚠️ `toArray()` 返回 `[Any]` ⇒ 要转成 JSValue
            let items = (v.toArray() ?? []).compactMap { $0 as? JSValue }
            return .array(items.map { toJSON($0) })
        }
        if v.isObject {
            // ⚠️ `toDictionary()` 返回 `[AnyHashable: Any]` ⇒ key 要转 String
            var obj: [String: JSONValue] = [:]
            for (k, val) in (v.toDictionary() ?? [:]) {
                guard let ks = k as? String, let jv = val as? JSValue else { continue }
                obj[ks] = toJSON(jv)
            }
            return .object(obj)
        }
        return .string(v.toString())
    }
}

/// JSC 侧的错误
public enum JSCError: Error, CustomStringConvertible {
    case contextUnavailable
    case scriptException(String)

    public var description: String {
        switch self {
        case .contextUnavailable: return "拿不到 JavaScriptCore 上下文"
        case .scriptException(let m): return "站方 JS 抛异常：\(m)"
        }
    }
}
#endif
