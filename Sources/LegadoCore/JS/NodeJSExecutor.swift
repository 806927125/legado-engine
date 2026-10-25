import Foundation

// ⭐⭐⭐⭐⭐ **Node 后端 = 【只给 Linux 沙盒用】**（2026-10-26 iOS CI 失败实证）
//
// ⚠️⚠️ **真凶**：`Foundation.Process` 是 **macOS-only** 的 API ⇒ **iOS 上压根不存在**
//   ⇒ `cannot find 'Process' in scope` ⇒ **BUILD FAILED** ⇒ 真机编不出包 ⭐⭐⭐
//   ⇒ 而 **Linux 沙盒编得过** ⇒ **沙盒绿 ≠ 真机编得过**（又抓到一个）⭐⭐⭐
//
// ⭐ **正解**：整个实现**只在 Linux 编译**；其它平台给一个 `isAvailable = false` 的 stub
//   ⇒ 引用方（Conformance）**不用改** ⇒ macOS 上自动走 JSC 分支 ⭐⭐⭐
//
// ⚠️ **通用教训**：往引擎里加**平台专属**代码 ⇒ 必须问「iOS/macOS 编得过吗」
//   ⇒ 沙盒只有 Linux ⇒ **平台专属的洞沙盒看不见** ⇒ 只能靠 CI 或显式闸门 ⭐⭐⭐
#if os(Linux)

/// ⭐⭐⭐⭐⭐ **Node 后端**（Linux / macOS 都能跑）—— 让**沙盒**能真跑站方 JS
///
/// ⚠️ **为什么需要**（2026-10-25 真机实证）：
/// · 轻阅那批「规则语义」门禁原本**在 jsdom 里跑老引擎 JS**
///   ⇒ 老引擎（WKWebView）退役并**物理删除** ⇒ 那些 JS 没了 ⇒ 门禁的对象没了
///   ⇒ 但**语义现在归新引擎管** ⇒ 门禁必须**改跑新引擎** ⇒ 否则覆盖就丢了 ⭐⭐⭐
/// · Linux 沙盒**没有 JSC** ⇒ 引擎的 `JSCExecutor` 在沙盒里不可用
///   ⇒ JS 相关的门禁全部只能 SKIP ⇒ **沙盒等于瞎的** ⇒ 只能一轮轮出包试真机 ⭐⭐⭐
///
/// ⇒ 正解：**给引擎加一个 Node 后端**（Node 的 `vm` 语义与 JSC 的 `eval` 完成值一致）
///   ⇒ 沙盒里能真跑站方 JS ⇒ 门禁全部复活 ⇒ **而且验的是新引擎**（真正在跑的那份）⭐⭐⭐
///
/// ⭐ **协议**（一行一个 JSON，stdinstdout 往返）：
/// - `{"cmd":"init","compat":[…],"wrappers":[…]}`  ⇒ 建上下文 + 注入兼容层与宿主包装函数
/// - `{"cmd":"runGlobal","code":"…"}`  ⇒ 间接 eval（全局作用域）⇒ 站方 jsLib 用
/// - `{"cmd":"run","code":"…","scope":"…"}`  ⇒ 在 scope 里 eval（完成值 = 站方代码的完成值）
/// - `{"cmd":"host","id":N,"object":"…","method":"…","argsJSON":"…"}`
///   ⇒ JS 侧调宿主（`__hostJSON`）⇒ 宿主回 `{"id":N,"result":"…"}`
public final class NodeJSExecutor: JSExecutor, @unchecked Sendable {

    /// ⭐⭐⭐ **Node 的路径**（`/usr/bin/env node` ⇒ 走 PATH）
    private static let nodePath = "/usr/bin/env"

    /// ⭐⭐⭐ Node 在不在（门禁用它做**显式 SKIP**，不许假绿）
    public static var isAvailable: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: nodePath)
        p.arguments = ["node", "--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    private var process: Process?
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let lock = NSLock()
    /// ⭐⭐⭐ **读缓冲**（`readabilityHandler` 累积 ⇒ 一行一行切出来）
    private var readBuffer = Data()
    /// ⭐⭐⭐ **待处理的回复**（每次 `send` 收一条）
    private var replies: [[String: Any]] = []
    /// ⭐⭐⭐ **等回复的条件**（`NSCondition` ⇒ Swift 侧同步等）
    private let replyCondition = NSCondition()

    /// ⭐⭐⭐ **宿主调用的回调**（JS 侧 `__hostJSON` ⇒ 回到这里）
    private var hostHandler: ((String, String, [JSONValue]) -> JSONValue?)?
    /// ⭐⭐⭐ **当前基准**（`java.getString('$.x')` 的 JSONPath 要对基准求值）
    private var currentBase: RuleBase = .page("")
    /// ⭐⭐⭐ **引擎侧接管 `java.*`**（`ajax` / `md5Encode` / …）
    private var engineAPI: JSEngineAPIHandler?
    /// ⭐⭐⭐ **要注入的宿主对象属性**（每次 run 更新）
    private var hostObjects: [String: HostObject] = [:]
    /// ⭐⭐⭐ **全局基线**（每次求值前清掉「不在基线里」的全局 ⇒ 站方 jsLib 的全局要留着）
    private var baselineGlobals: Set<String> = []
    /// ⭐⭐⭐⭐⭐ **静态路由表**（假服务器 ⇒ Node 侧的 `java.ajax` 能同步查表）
    ///
    /// ⚠️ **为什么需要**（2026-10-25）：站方包装函数是**同步**调 `__hostJSON`
    ///   ⇒ Node 的宿主往返是**异步** ⇒ 同步代码拿不到结果
    ///   ⇒ 路由是**静态**的 ⇒ **在 JS 侧查表**才是同步的正解 ⭐⭐⭐
    private var routeTable: [[String: Any]] = []

    public init() throws {
        guard NodeJSExecutor.isAvailable else {
            throw SourceError.unsupported("Node 后端不可用（没装 node）")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: NodeJSExecutor.nodePath)
        p.arguments = ["node", "-e", NodeJSExecutor.harnessSource]
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = Pipe()
        // ⭐⭐⭐ **node 的 stderr 要看得见**（不然 node 崩了/报错 ⇒ **静默丢失** ⇒ 门禁只看到「引擎退出码 null」）⭐⭐⭐
        //   ⇒ 转发到本进程的 stderr ⇒ 排查时能直接看到 node 的真实报错 ⭐
        let errPipe = Pipe()
        p.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            FileHandle.standardError.write(chunk)
        }
        try p.run()
        process = p
        // ⭐⭐⭐ **用 readabilityHandler 读**（不能用 `availableData` 循环）
        //   ⚠️ `availableData` 在管道里会**阻塞/返回 0** ⇒ 读不到 ⇒ 表现为「node 不回复」⭐⭐⭐
        //   ⚠️ 而且 node 写 stdout 时 Swift 侧已退出 ⇒ **SIGPIPE（signal 13）**⇒ 进程被杀 ⭐⭐⭐
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.replyCondition.lock()
            self.readBuffer.append(chunk)
            while let nl = self.readBuffer.firstIndex(of: 0x0A) {
                let line = self.readBuffer[..<nl]
                self.readBuffer.removeSubrange(...nl)
                if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    self.replies.append(obj)
                }
            }
            self.replyCondition.signal()
            self.replyCondition.unlock()
        }
        // ⭐ 初始化：注入 Java 兼容层 + 宿主包装函数
        _ = try send(["cmd": "init",
                      "compat": JavaCompat.sources,
                      "wrappers": JSScopeBuilder.hostWrappers(),
                      "routes": routeTable])
    }

    deinit {
        // ⭐⭐⭐⭐⭐ **必须先拆掉 readabilityHandler 再 terminate**（2026-10-25 踩过）
        //   ⚠️ 否则：Swift 侧退出了 ⇒ node 还在往 stdout 写 ⇒ **SIGPIPE（signal 13）**
        //   ⇒ 表现为「测试进程被 signal 13 杀掉」⇒ 看起来像「Node 后端有问题」其实是**收尾姿势**的问题 ⭐⭐⭐
        // ⭐⭐⭐ **先发 `quit` 让 node 自己退出**（别直接 terminate ⇒ 它写 stdout 时会吃 SIGPIPE）⭐⭐⭐
        if let pr = process, pr.isRunning {
            if let line = try? JSONSerialization.data(withJSONObject: ["cmd": "quit"]) {
                try? stdin.fileHandleForWriting.write(Line(line))
            }
            let deadline = Date().addingTimeInterval(0.3)
            while pr.isRunning && Date() < deadline { usleep(20000) }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        // ⭐⭐⭐ **等 node 自己退出**（terminate 会让它在写 stdout 时吃 SIGPIPE）
        if let pr = process {
            pr.terminate()
            // ⭐ 给它一点时间把缓冲区写完（写不出去就忽略 SIGPIPE 退出）
            let deadline = Date().addingTimeInterval(0.5)
            while pr.isRunning && Date() < deadline {
                usleep(20000)
            }
            if pr.isRunning { kill(pr.processIdentifier, SIGKILL) }
        }
    }

    // MARK: - 传输

    /// ⭐ 一行 JSON（带换行）
    private func Line(_ data: Data) -> Data {
        var d = data
        d.append(0x0A)
        return d
    }

    private func send(_ payload: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw SourceError.unsupported("Node 命令序列化失败")
        }
        stdin.fileHandleForWriting.write(Data((line + "\n").utf8))
        // ⭐⭐⭐ **等一条回复**（`readabilityHandler` 累积 ⇒ 这里取走一条）
        replyCondition.lock()
        defer { replyCondition.unlock() }
        let deadline = Date().addingTimeInterval(30)
        while replies.isEmpty {
            if !replyCondition.wait(until: deadline) {
                throw SourceError.unsupported("Node 后端超时（30 秒没回复）")
            }
        }
        return replies.removeFirst()
    }

    // MARK: - JSExecutor

    /// ⭐⭐⭐ **求值**（scope + eval ⇒ 完成值 = 站方代码的完成值）
    public func run(_ code: String, context: JSRunContext) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        currentBase = context.base
        hostObjects = Self.hostObjects(from: context)
        // ⭐⭐⭐ **宿主对象的属性要每次更新**（编排层随时会换 source/book/chapter）⭐⭐⭐
        let props = Self.hostPropertiesPayload(context)
        let scope = JSScopeBuilder.build(context)
        // ⭐⭐⭐ **预计算纯计算方法**（站方包装函数是**同步**的 ⇒ JS 侧只能查表）⭐⭐⭐
        let cache = Self.pureMethodCache(engineAPI: engineAPI, base: currentBase, code: code)
        let reply = try send(["cmd": "run", "code": code, "scope": scope,
                              "hostProps": props, "hostCache": cache])
        if let err = reply["error"] as? String {
            throw SourceError.unsupported("Node JS 报错：\(err)")
        }
        return JSONValue.from(reply["value"] ?? NSNull())
    }

    /// ⭐⭐⭐ **全局求值**（站方 jsLib ⇒ 间接 eval ⇒ 留在全局）
    public func runGlobal(_ code: String, context: JSRunContext) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        let reply = try send(["cmd": "runGlobal", "code": code])
        if let err = reply["error"] as? String {
            throw SourceError.unsupported("Node JS（jsLib）报错：\(err)")
        }
        // ⭐⭐⭐ **重设基线**（站方 jsLib 定义的全局要长期保留）⭐⭐⭐
        baselineGlobals = Set((reply["globals"] as? [String]) ?? [])
        return JSONValue.from(reply["value"] ?? NSNull())
    }

    /// ⭐⭐⭐ **引擎侧接管 `java.*`**
    public func setEngineAPI(_ handler: JSEngineAPIHandler?) {
        engineAPI = handler
    }

    /// ⭐⭐⭐⭐⭐ **设置静态路由表（假服务器）** ⇒ `java.ajax` 在 Node 侧同步查表
    public func setRoutes(_ routes: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        routeTable = routes
        _ = try? send(["cmd": "routes", "routes": routes])
    }

    /// ⭐⭐⭐⭐⭐ **取回请求记录**（门禁要看「发了哪几条」）
    public func recordedRequests() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let reply = try? send(["cmd": "requests"]), let r = reply["requests"] as? [String] else {
            return []
        }
        return r
    }

    // MARK: - ⭐⭐⭐ 宿主对象的状态（沙盒专用）

    /// ⭐⭐⭐⭐⭐ **灌入宿主对象的状态**（`source.*` / `cookie.*` 的数据）⭐⭐⭐⭐⭐
    ///
    /// ⚠️ **为什么需要**（2026-10-25 迁移门禁时实证）：
    ///   Node 后端**没法同步回调 Swift**（宿主往返是异步的 ⇒ 同步的站方 JS 拿不到结果）
    ///   ⇒ 宿主对象（`source.getLoginInfoMap()` / `cookie.getCookie(url)` / …）在 Node 侧
    ///   **全是 undefined** ⇒ 站方的登录脚本第一步就炸（TypeError）⇒ **登录链路没法在沙盒验**⭐⭐⭐
    ///   ⇒ 正解：**读** = Swift 把数据灌进来（快照）；**写** = JS 侧记下来 ⇒ 跑完 Swift 收走 ⭐
    ///   ⇒ 与 App 侧的做法同款（App 靠 `__sourceVars` / `__loginInfo` 回传）⭐
    public func setHostState(_ state: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        _ = try? send(["cmd": "hostState", "state": state])
    }

    /// ⭐⭐⭐⭐⭐ **灌入假浏览器**（`java.startBrowserAwait` 在沙盒里能跑）⭐⭐⭐⭐⭐
    ///
    /// ⚠️ 站方 🍅番茄登录靠「浏览器里登出来的 sessionid 回到引擎的 cookie 罐」⇒
    ///   没有它 ⇒ 登录第 ③ 步拿不到凭据 ⇒ **整条链没法验** ⭐⭐⭐
    public func setBrowserPages(_ pages: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        _ = try? send(["cmd": "browserPages", "pages": pages])
    }

    /// ⭐⭐⭐ **取回「开过哪些浏览器」**（门禁要断言「引擎让宿主弹了浏览器」）⭐⭐⭐
    public func recordedBrowsers() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let reply = try? send(["cmd": "browsers"]), let b = reply["browsers"] as? [String] else {
            return []
        }
        return b
    }

    /// ⭐⭐⭐ **取回宿主对象的状态**（站方改过的变量 / 登录信息 / cookie 都在里面）
    public func hostState() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let reply = try? send(["cmd": "hostState"]), let st = reply["state"] as? [String: Any] else {
            return [:]
        }
        return st
    }

    /// ⭐⭐⭐ **标记全局基线**（jsLib 跑完后调）
    public func markGlobalsAsBaseline() {
        lock.lock(); defer { lock.unlock() }
        if let reply = try? send(["cmd": "globals"]), let g = reply["globals"] as? [String] {
            baselineGlobals = Set(g)
        }
    }

    /// ⭐⭐⭐ **作废 context**
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        _ = try? send(["cmd": "invalidate"])
        baselineGlobals = []
    }

    // MARK: - 宿主通道

    /// ⭐⭐⭐ **从求值上下文里取宿主对象**（与 JSCExecutor 同口径）
    private static func hostObjects(from ctx: JSRunContext) -> [String: HostObject] {
        var out: [String: HostObject] = [:]
        if let s = ctx.source { out["source"] = s }
        if let b = ctx.book { out["book"] = b }
        if let c = ctx.chapter { out["chapter"] = c }
        return out
    }

    /// ⭐⭐⭐ **宿主对象的属性**（每次 run 更新 ⇒ 传给 Node）
    private static func hostPropertiesPayload(_ ctx: JSRunContext) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for (name, obj) in hostObjects(from: ctx) {
            var props: [String: Any] = [:]
            for (k, v) in obj.properties { props[k] = v.foundationValue }
            out[name] = props
        }
        return out
    }

    /// ⭐⭐⭐ **Node 侧调宿主**（`__hostJSON` 的 Swift 实现）
    fileprivate func handleHost(_ object: String, _ method: String, _ argsJSON: String) -> String {
        var args: [JSONValue] = []
        if let data = argsJSON.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            args = arr.map { JSONValue.from($0) }
        }
        // ⭐⭐⭐ **引擎侧优先接管**（`ajax` / `md5Encode` / …）
        var result: JSONValue?
        if object == "java", let engineAPI, let r = engineAPI(method, args, currentBase) {
            result = r
        } else {
            // ⭐ 宿主实现（App 侧）
            result = nil   // ⭐ Node 后端没有宿主实现 ⇒ 返回 undefined（引擎侧能做的自己做了）
        }
        let any = result.map { $0.foundationValue } ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: [any]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    /// ⭐⭐⭐⭐⭐ **Node harness 源码**（内嵌 ⇒ 零资源依赖）
    ///
    /// ⚠️ **必须复刻引擎的 eval 语义**：
    ///   JSCExecutor 是 `scope + "\n" + "(function(){ return eval(<codeLiteral>); })()"`
    ///   ⇒ **代码是字符串字面量** ⇒ 完成值 = eval 的值 ⭐⭐⭐
    ///   ⇒ 直接 `eval(code)`（不是字符串）**语义不同** ⇒ 会造成假绿/假红 ⭐⭐⭐
    /// ⭐⭐⭐⭐⭐ **纯计算方法的预计算**
    ///
    /// ⚠️ **哪些能预计算**：**纯计算**（不碰网络/cookie/全局）的 `java.*`
    /// ⚠️ **哪些不能**：`ajax`（要发请求）⇒ 沙盒跑不了 ⇒ 那条路径 SKIP（真机走 JSC 后端）⭐⭐⭐
    private static func pureMethodCache(engineAPI: JSEngineAPIHandler?,
                                        base: RuleBase,
                                        code: String = "") -> [String: String] {
        guard let engineAPI else { return [:] }
        var out: [String: String] = [:]
        // ⭐ 站方包装函数的调用形态：`__hostJSON('java','base64Encode', JSON.stringify([args…]))`
        //   ⇒ 缓存 key 用**同样形态** ⇒ Node 侧查表能命中 ⭐⭐⭐
        for method in ["base64Encode", "base64Decode", "md5Encode", "sha1Encode", "timeFormat",
                       "hexDecodeToString", "hexEncodeToString", "base64DecodeSafe"] {
            guard let r = engineAPI(method, [], base) else { continue }
            let any = r.foundationValue
            guard let data = try? JSONSerialization.data(withJSONObject: [any]),
                  let text = String(data: data, encoding: .utf8) else { continue }
            out["java|\(method)|[]"] = text
        }
        // ⭐⭐⭐⭐⭐ **代码里出现的 `java.getString('字面量')` 等 ⇒ 提前算好**（2026-10-26 门禁迁移时补）
        //
        // ⚠️ **为什么必须提前算**：Node 的宿主往返是**异步** ⇒ 同步的包装函数拿不到结果 ⭐⭐⭐
        //   ⇒ 而 `java.getString('$.x')` 这种**带字面量参数**的调用**每个基准都不一样**
        //   ⇒ 没法像纯计算方法那样一次性算好 ⇒ **只能从【这次要跑的代码】里把字面量抠出来** ⭐⭐⭐
        //
        // ⭐ **为什么重要**：站方 379 个真源里 **90 个（24%）** 的规则里有
        //   `{{java.getString('$.status')=='50'?'完结':'连载'}}` 这种写法 ⭐⭐⭐
        //   ⇒ 不算 ⇒ 沙盒里这些源的**分类 / 简介 / 更新时间全是空** ⇒ 门禁验不到 ⭐⭐⭐
        if !code.isEmpty {
            for method in ["getString", "get"] {
                for arg in Self.literalArgs(of: method, in: code) {
                    guard let r = engineAPI(method, [.string(arg)], base) else { continue }
                    let any = r.foundationValue
                    // ⚠️⚠️ **缓存 key 的参数个数必须跟【包装函数】一样**（`hostWrappers` 固定 4 个参数）
                    //   ⇒ 包装函数传的是 `JSON.stringify([a0,a1,a2,a3])` ⇒ 未传的位是 `null`
                    //   ⇒ key 必须也带 3 个 null ⇒ 否则**永远查不到**（静默 undefined）⭐⭐⭐
                    let keyArgs: [Any] = [arg, NSNull(), NSNull(), NSNull()]
                    guard let data = try? JSONSerialization.data(withJSONObject: [any]),
                          let text = String(data: data, encoding: .utf8),
                          let keyData = try? JSONSerialization.data(withJSONObject: keyArgs),
                          let key = String(data: keyData, encoding: .utf8) else { continue }
                    out["java|\(method)|\(key)"] = text
                }
            }
        }
        return out
    }

    /// ⭐⭐⭐ **从代码里抠出 `java.<method>('字面量')` 的字面量参数**
    private static func literalArgs(of method: String, in code: String) -> [String] {
        guard let re = try? NSRegularExpression(
            pattern: "java\\.\(method)\\(\\s*(['\"])([^'\"]*)\\1\\s*\\)") else { return [] }
        let ns = code as NSString
        var out: [String] = []
        re.enumerateMatches(in: code, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 3 else { return }
            let v = ns.substring(with: m.range(at: 2))
            if !out.contains(v) { out.append(v) }
        }
        return out
    }

    static let harnessSource = #"""
'use strict';
// ⭐⭐⭐⭐⭐ **忽略 SIGPIPE**（2026-10-25 踩过）
//   ⚠️ Swift 侧退出后 node 往 stdout 写 ⇒ **SIGPIPE（signal 13）**⇒ 整个测试进程被杀
//   ⇒ 表现为「Node 后端有问题」⇒ 其实是**收尾姿势**的问题 ⭐⭐⭐
process.on('SIGPIPE', function() { process.exit(0); });
const vm = require('vm');
const ctx = vm.createContext({ console });
let hostSeq = 1;
const pending = new Map();

// ⭐⭐⭐ **宿主通道**（Swift 侧通过 stdin 的 host 命令应答）
ctx.__hostCall = function(object, method, argsJSON) {
  const id = hostSeq++;
  return new Promise(function(resolve) {
    pending.set(id, resolve);
    process.stdout.write(JSON.stringify({ cmd: 'host', id: id, object: object,
                                         method: method, argsJSON: argsJSON }) + '\n');
  });
};
// ⭐ 包装函数用的是**同步** `__hostJSON` ⇒ 这里给一个同步版本（Node 的 host 往返是异步的）
//   ⇒ 引擎的包装函数是同步的 ⇒ Node 里没法同步等 ⇒ 这里用**同步阻塞**（Atomics 风格不适用）
//   ⇒ 改用：把宿主调用**批处理**在每次 run 前预先算好（见 run 的 hostProps）⭐⭐⭐
// ⭐⭐⭐⭐⭐ **纯计算方法在【JS 侧】直接实现**（2026-10-25 踩过）
//
// ⚠️ **为什么不能在 Swift 侧预计算**：
// · 站方包装函数是**同步**调 `__hostJSON(...)` ⇒ JS 侧拿不到异步往返的结果
// · 而这些方法**有参数**（`java.base64Encode(文本)`）⇒ 参数运行时才知道
//   ⇒ Swift 侧**没法预计算**（只能预计算无参的）⇒ 命中不了 ⇒ `java.base64Encode` 返回 null ⭐⭐⭐
//
// ⇒ 正解：**在 JS 侧实现这几个纯方法**（Node 内置能力 ⇒ 零 Swift 往返）⭐⭐⭐
// ⚠️ `java.ajax`（要发请求）**不能**这样 ⇒ 沙盒里那条路径仍不可用（真机走 JSC）⭐⭐⭐
ctx.__qrPure = {
  base64Encode: function(s) {
    return Buffer.from(String(s === undefined ? '' : s), 'utf8').toString('base64');
  },
  // ⭐⭐⭐⭐⭐ **base64 解码必须与 Swift 的 `Crypto.base64Decode` 同语义**（2026-10-25 真机/沙盒不一致）
  //
  // ⚠️⚠️ **原来的 bug**：`Buffer.from(s,'base64')` **静默忽略非法字符**
  //   ⇒ `aGVsbG8%2B` ⇒ 丢掉 `%2` ⇒ 解出 `hello6`（**错的**）
  //   ⇒ 而 Swift 侧 `Crypto.base64Decode` 会**先归一化**（%2B ⇒ +）⇒ 解出 `hello>`（**对的**）
  //   ⇒ ⇒ **沙盒 ≠ 真机** ⇒ 门禁跑出来的是假象 ⇒ 既会掩盖真 bug，也会造出假 bug ⭐⭐⭐
  //
  // ⭐ 正解：**在 JS 侧实现同一套归一化**（b64normalize）
  //   ① 百分号转义还原（只还原 base64 合法字符）
  //   ② URL 安全字符（- / _）⇒ 标准 base64（+ / /）
  //   ③ 空格 ⇒ +
  b64normalize: function(s) {
    var t = String(s === undefined ? '' : s);
    // ① 百分号转义还原
    t = t.replace(/%([0-9A-Fa-f]{2})/g, function(m, hex) {
      var ch = String.fromCharCode(parseInt(hex, 16));
      return /[A-Za-z0-9+/=\-_]/.test(ch) ? ch : m;
    });
    // ② URL 安全字符 ⇒ 标准 base64
    t = t.replace(/-/g, '+').replace(/_/g, '/');
    // ③ 空格 ⇒ +
    t = t.replace(/ /g, '+');
    return t;
  },
  base64Decode: function(s) {
    try {
      var t = ctx.__qrPure.b64normalize(s);
      if (!/^[A-Za-z0-9+/]*={0,2}$/.test(t)) return '';
      var buf = Buffer.from(t, 'base64');
      // ⚠️ Node 的 base64 解码**静默忽略非法字符** ⇒ 必须自己校验长度
      if (t.replace(/=+$/, '').length % 4 === 1) return '';
      return buf.toString('utf8');
    } catch (e) { return ''; }
  },
  md5Encode: function(s) {
    return require('crypto').createHash('md5')
      .update(String(s === undefined ? '' : s), 'utf8').digest('hex');
  },
  // ⭐⭐⭐ **sha1Encode**（2026-10-26 补 ⇒ 老引擎有、新引擎缺的能力）
  //   ⚠️ 必须与 Swift 侧 `Crypto.sha1Hex` **同语义**（小写 hex、UTF-8 字节）⭐⭐⭐
  sha1Encode: function(s) {
    return require('crypto').createHash('sha1')
      .update(String(s === undefined ? '' : s), 'utf8').digest('hex');
  },
  // ⭐⭐⭐⭐⭐ **hexDecodeToString 必须与 Swift 的 `Crypto.hexDecodeToString` 同语义**
  //
  // ⚠️ **原来的 bug**：JS 版**只做 hex** ⇒ base64 载荷一律返回空
  //   ⇒ 而 Swift 侧是「**先试 hex，失败再按 base64 试一次**」（站方约定：载荷可能是两种）
  //   ⇒ 站方（大灰狼）拿 base64 喂 `hexDecodeToString` ⇒ **沙盒解不出来，真机能解** ⭐⭐⭐
  //   ⇒ ⇒ **沙盒 ≠ 真机** ⇒ 门禁跑出来的是假象 ⭐⭐⭐
  hexDecodeToString: function(s) {
    const t = String(s === undefined ? '' : s).trim();
    // ① 先试严格 hex（长度偶数 + 字符合法）
    if (t.length > 0 && t.length % 2 === 0 && /^[0-9a-fA-F]+$/.test(t)) {
      let out = '';
      for (let i = 0; i + 1 < t.length; i += 2) {
        out += String.fromCharCode(parseInt(t.slice(i, i + 2), 16));
      }
      return out;
    }
    // ② 失败 ⇒ 按 base64 再试一次（与 Swift 一致）
    return ctx.__qrPure.base64Decode(t);
  },
  // ⭐⭐⭐⭐⭐ **`java.timeFormat` / `java.timeFormatUTC`** —— 站方 125 源实测 60+ 处在用 ⭐⭐⭐⭐⭐
  //
  // ⚠️⚠️ **为什么必须有**（2026-10-25 迁移门禁时实证）：
  //   · 站方的**会员卡片**就是靠它：`java.timeFormat(res.register_time*1000).padEnd(20,"\t")`
  //   · Node 后端原来**没有这个纯方法** ⇒ `java.timeFormat(...)` 返回 **undefined**
  //   ⇒ 站方 `.padEnd` 直接抛 `Cannot read properties of undefined (reading 'padEnd')`
  //   ⇒ 卡片拼不出来 ⇒ 站方报「检测登录失败」⇒ **用户以为没登录，其实登录是好的** ⭐⭐⭐
  //   （这正是老引擎时代那个真机 bug 的同款 ⇒ 沙盒必须能验它）⭐
  //
  // ⭐ **语义必须与 Swift 的 `TimeFormat` 一致**（沙盒 ≠ 真机 ⇒ 门禁跑出来的是假象）⭐
  //   · 入参：epoch **毫秒**（纯数字）或常见日期串
  //   · 出参：**字符串**（默认 `yyyy-MM-dd HH:mm:ss`）⇒ 站方的 `.padEnd` 才不会炸 ⭐⭐⭐
  timeFormat: function(s, pattern, tzOffset) {
    return ctx.__qrPure.__qrFormatTime(String(s === undefined || s === null ? '' : s),
                                       pattern, tzOffset, false);
  },
  timeFormatUTC: function(s, pattern, tzOffset) {
    return ctx.__qrPure.__qrFormatTime(String(s === undefined || s === null ? '' : s),
                                       pattern, tzOffset, true);
  },
  // ⭐ 入参 → epoch 毫秒（与 Swift 的 `TimeFormat.millis(from:)` 同口径）
  __qrMillis: function(v) {
    var t = String(v === undefined || v === null ? '' : v).trim();
    if (!t) return null;
    if (/^-?\d+$/.test(t)) return Number(t);
    var m = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$/.exec(t);
    if (m) {
      return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]),
                      Number(m[4] || 0), Number(m[5] || 0), Number(m[6] || 0)).getTime();
    }
    var m2 = /^(\d{1,2})-(\d{1,2}) (\d{1,2}):(\d{1,2})(?::(\d{1,2}))?$/.exec(t);
    if (m2) {
      return new Date(1970, 0, Number(m2[1]), Number(m2[3]), Number(m2[4]), Number(m2[5] || 0)).getTime();
    }
    return null;
  },
  // ⭐ 毫秒 → 格式化串（Java pattern 的常用子集：yyyy / MM / dd / HH / mm / ss）
  __qrFormatTime: function(v, pattern, tzOffset, isUTC) {
    var ms = ctx.__qrPure.__qrMillis(v);
    if (ms === null) return '';
    var off = (tzOffset === undefined || tzOffset === null || tzOffset === '') ? null : Number(tzOffset);
    var useOff = (off !== null && !isNaN(off));
    var dt = new Date(useOff ? ms + off * 3600 * 1000 : ms);
    var Y = useOff ? dt.getUTCFullYear() : dt.getFullYear();
    var Mo = (useOff ? dt.getUTCMonth() : dt.getMonth()) + 1;
    var D = useOff ? dt.getUTCDate() : dt.getDate();
    var H = useOff ? dt.getUTCHours() : dt.getHours();
    var Mi = useOff ? dt.getUTCMinutes() : dt.getMinutes();
    var S = useOff ? dt.getUTCSeconds() : dt.getSeconds();
    function p2(n) { return (n < 10 ? '0' : '') + n; }
    var p = pattern || 'yyyy-MM-dd HH:mm:ss';
    return p.replace(/yyyy|MM|dd|HH|mm|ss/g, function(m) {
      if (m === 'yyyy') return String(Y).padStart(4, '0');
      if (m === 'MM') return p2(Mo);
      if (m === 'dd') return p2(D);
      if (m === 'HH') return p2(H);
      if (m === 'mm') return p2(Mi);
      if (m === 'ss') return p2(S);
      return m;
    });
  },
  hexEncodeToString: function(s) {
    let out = '';
    const t = String(s === undefined ? '' : s);
    for (let i = 0; i < t.length; i++) {
      out += t.charCodeAt(i).toString(16).padStart(2, '0');
    }
    return out;
  },
};

// ⭐⭐⭐⭐⭐ **假服务器（静态路由）** —— 让 Node 后端能跑 `java.ajax`
//
// ⚠️ **为什么必须做在 JS 侧**（2026-10-25 踩过）：
// · 站方包装函数是**同步**调 `__hostJSON(...)`
// · 而 Node 的宿主往返是**异步**（stdin/stdout）⇒ 同步代码拿不到结果
// · ⇒ 「Swift 侧发请求再回传」这条路在 Node 后端**走不通** ⭐⭐⭐
//
// ⭐ **正解**：路由是**静态**的（URL → 固定 body）⇒ **在 JS 侧查表**即可
//   ⇒ 完全同步 ⇒ 站方的 catch 换线 / 重试逻辑能原样跑 ⭐⭐⭐
//   ⇒ 真机走真网络，但**站方看到的语义一样**（ajax 返回 body 字符串）⇒ 门禁语义对得上 ⭐⭐⭐
//
// ⭐ 路由格式：[{ match: 'a.example.com', status: 502, body: '…' }]
//   · `match` 是**子串匹配**（对 URL 去 query 后匹配）
//   · 未命中 ⇒ 404（**明确失败** ⇒ 不静默 200 造成假绿）⭐⭐⭐
ctx.__qrRoutes = ctx.__qrRoutes || [];
ctx.__qrRequests = ctx.__qrRequests || [];

// ⭐⭐⭐⭐⭐ **宿主对象的状态**（`source.*` / `cookie.*`）⭐⭐⭐⭐⭐
//
// ⚠️⚠️ **为什么要有**（2026-10-25 迁移门禁时实证）：
// · 站方的**登录脚本**重度依赖宿主对象：
//     source.getLoginInfoMap()   ← 表单值（轻阅的输入框）
//     source.putLoginInfo(info)  ← 站方存登录信息
//     source.getKey()            ← 缓存 key
//     cookie.getCookie(url)      ← 站方读 cookie
//     cookie.getKey(host, name)  ← 🍅番茄登录第 ③ 步
// · 而 Node 后端**没法同步回调 Swift**（宿主往返是异步）⇒ 这些方法在 Node 侧**全是 undefined**
// · ⇒ 站方脚本第一步就 TypeError ⇒ **登录链路在沙盒里没法验** ⭐⭐⭐
//
// ⭐ **正解**（与 App 侧同款）：
//   **读** = Swift 把数据灌进来（快照）· **写** = JS 侧记下来 ⇒ 跑完 Swift 收走
//   ⇒ 语义与 Swift 的 `makeSourceObject` / `makeCookieObject` **逐条对齐** ⭐⭐⭐
//     （Swift 那套是 JSC/真机上的实现；这里是 **Node 沙盒**的等价实现 ⇒ 门禁验的是同一套语义）
//
// ⚠️⚠️ **必须注入到【vm 里面】**（不是在 node 的模块作用域里）：
//   `source` / `cookie` 这两个壳是 `vm.runInContext('var source={},…')` 建的
//   ⇒ **只存在于 vm 里** ⇒ 在 node 作用域写 `source.getVariable = …` ⇒ `source is not defined`
//   ⇒ **整个安装函数挂掉**（⇒ `cookie.getCookie` 仍是「调宿主」版 ⇒ 返回 undefined）⭐⭐⭐
// ⭐⭐⭐⭐⭐ **浏览器（假浏览器）** —— 让 `java.startBrowserAwait` 在沙盒里能跑 ⭐⭐⭐⭐⭐
//
// ⚠️⚠️ **为什么需要**（2026-10-25 迁移门禁时实证）：
//   · 站方 🍅番茄登录（`fq_login()`）的流程是：
//     ① cookie.removeCookie('fanqienovel.com')   ← **先把旧 cookie 删掉**
//     ② java.startBrowserAwait('https://fanqienovel.com/', '登录')  ← 用户在浏览器里登录
//     ③ cookie.getKey('fanqienovel.com', 'sessionid')  ← **浏览器里登出来的 cookie 必须回到引擎**
//   · ① 之后 cookie 是空的 ⇒ ③ 拿不到凭据 ⇒ 除非**宿主把浏览器的 cookie 合并回来**⭐⭐⭐
//   · 而 Node 后端的宿主调用**回不到 Swift** ⇒ 浏览器只能做在 **JS 侧**（跟 `java.ajax` 一样）⭐
//   · 形态：`[{ match: 'fanqienovel.com', html: '…', cookies: { 'fanqienovel.com': 'sessionid=…' } }]`
//     ⇒ `cookies` = 「用户在浏览器里登录后，宿主合并回来的 cookie」（真机上是 `HTTPCookieStorage`）⭐⭐⭐
ctx.__qrBrowserPages = ctx.__qrBrowserPages || [];
ctx.__qrBrowsers = ctx.__qrBrowsers || [];

const HOST_OBJECT_SHIM = `
(function(){
  function H() {
    if (!globalThis.__qrHostState) {
      globalThis.__qrHostState = {
        source: { url: '', name: '', group: '', vars: {}, loginInfo: {}, loginHeader: '' },
        cookie: { jar: {} }
      };
    }
    return globalThis.__qrHostState;
  }
  // ⭐ 字符串 → 变量表（站方可能传 JSON 串，也可能传对象）
  function toVarMap(v) {
    var out = {};
    if (v === undefined || v === null) return out;
    if (typeof v === 'string') {
      var t = v.trim();
      if (!t) return out;
      try {
        var o = JSON.parse(t);
        if (o && typeof o === 'object') {
          for (var k in o) { if (Object.prototype.hasOwnProperty.call(o, k)) out[k] = String(o[k]); }
        }
      } catch (e) { /* 不是 JSON ⇒ 空表 */ }
      return out;
    }
    if (typeof v === 'object') {
      for (var k2 in v) { if (Object.prototype.hasOwnProperty.call(v, k2)) out[k2] = String(v[k2]); }
    }
    return out;
  }
  // ⭐ cookie 的键（老引擎按 **host** 存；这里 URL / host 两种都试 ⇒ 与真机 CookieJar 的域匹配同思路）
  function cookieKeyOf(url) {
    var u = String(url === undefined ? '' : url);
    var host = '';
    try { host = new URL(u).host; } catch (e) {
      // ⚠️ **不能用正则**（里面的双斜杠会把正则字面量截断 ⇒ 语法错 ⇒ 整个 shim 装不上）⭐⭐⭐
      //   ⇒ 用 split 取第 3 段（'https:' / '' / 'host' / …）⭐
      var seg = u.split('/');
      if (seg.length > 2) host = seg[2];
    }
    return { url: u, host: host };
  }
  function cookieLookup(url) {
    var jar = H().cookie.jar || {};
    var k = cookieKeyOf(url);
    if (Object.prototype.hasOwnProperty.call(jar, k.url)) return jar[k.url];
    if (k.host && Object.prototype.hasOwnProperty.call(jar, k.host)) return jar[k.host];
    return '';
  }
  globalThis.__qrInstallHostObjects = function() {
    var st = H();
    // ── source.* ────────────────────────────────────────────
    source.getVariable = function () {
      // ⚠️⚠️ **空变量 ⇒ 返回【空串】**（不是 "{}"）—— 与 Swift 的 varsJSON **逐字一致**⭐⭐⭐
      //   ⇒ 站方（🍅大灰狼）的 getArguments('','server') 靠 **JSON.parse 失败** 才给默认表
      //     （server: host[0] / tab / sources …）
      //   ⇒ 返回 "{}" ⇒ parse 成功 ⇒ 默认表**整个丢掉** ⇒ server 变 undefined ⭐⭐⭐
      //   ⇒ 老引擎的 wrapSource 也是这个语义（vars = src.__variables 原样返回）⭐
      var vars = st.source.vars || {};
      var keys = Object.keys(vars);
      if (!keys.length) return '';
      return JSON.stringify(vars);
    };
    source.setVariable = function (a, b) {
      if (a && typeof a === 'object') { st.source.vars = toVarMap(a); return ''; }
      if (b !== undefined) { st.source.vars[String(a)] = String(b); return ''; }
      st.source.vars = toVarMap(a);
      return '';
    };
    source.get = function (k) {
      var v = (st.source.vars || {})[String(k)];
      return (v === undefined || v === null) ? '' : String(v);
    };
    source.put = function (k, v) {
      st.source.vars = st.source.vars || {};
      st.source.vars[String(k)] = (v === undefined || v === null) ? '' : String(v);
      return '';
    };
    source.getKey = function () { return String(st.source.url || ''); };
    // ⭐⭐⭐⭐⭐ **登录信息：优先读引擎发布的那份**（引擎发布的 __qrLoginInfo）⭐⭐⭐⭐⭐
    //   ⇒ 引擎在跑 action 之前把「表单值合并后的登录信息」发布到全局
    //   ⇒ 站方 source.getLoginInfoMap() 必须读到**合并之后**那份
    //     （否则用户填了密码，点了「解锁整个源」还是提示「没填密码」⇒ 老 bug 复发）⭐⭐⭐
    function loginInfoNow() {
      if (globalThis.__qrLoginInfo && typeof globalThis.__qrLoginInfo === 'object') {
        return globalThis.__qrLoginInfo;
      }
      return st.source.loginInfo || {};
    }
    source.getLoginInfoMap = function () { return loginInfoNow(); };
    source.getLoginInfo = function () { return JSON.stringify(loginInfoNow()); };
    source.putLoginInfo = function (a, b) {
      var info;
      if (a && typeof a === 'object') { info = toVarMap(a); }
      else if (b !== undefined) {
        info = Object.assign({}, loginInfoNow());
        info[String(a)] = String(b);
      } else { info = toVarMap(a); }
      st.source.loginInfo = info;
      globalThis.__qrLoginInfo = info;
      return '';
    };
    source.getLoginHeader = function () { return String(st.source.loginHeader || ''); };
    source.putLoginHeader = function (v) {
      st.source.loginHeader = (v === undefined || v === null) ? '' : String(v);
      return '';
    };
    try { source.bookSourceUrl = st.source.url || ''; } catch (e) {}
    try { source.bookSourceName = st.source.name || ''; } catch (e) {}
    try { source.bookSourceGroup = st.source.group || ''; } catch (e) {}
    // ── cookie.* ────────────────────────────────────────────
    cookie.getCookie = function (url) { return cookieLookup(url); };
    cookie.setCookie = function (url, value) {
      var k = cookieKeyOf(url);
      H().cookie.jar = H().cookie.jar || {};
      // ⭐ 与真机 CookieJar 同思路：**域**为主键（同一个域的两次写要能互相看到）
      var key = k.host || k.url;
      H().cookie.jar[key] = (value === undefined || value === null) ? '' : String(value);
      if (k.url) H().cookie.jar[k.url] = H().cookie.jar[key];
      return '';
    };
    cookie.removeCookie = function (url) {
      var k = cookieKeyOf(url);
      H().cookie.jar = H().cookie.jar || {};
      delete H().cookie.jar[k.url];
      if (k.host) delete H().cookie.jar[k.host];
      return '';
    };
    cookie.replaceCookie = function (url, value) {
      cookie.removeCookie(url);
      cookie.setCookie(url, value);
      return '';
    };
    cookie.getKey = function (host, name) {
      var c = cookieLookup(host);
      if (!c) return '';
      var parts = String(c).split(';');
      for (var i = 0; i < parts.length; i++) {
        var p = parts[i].trim();
        var idx = p.indexOf('=');
        if (idx > 0 && p.slice(0, idx) === String(name)) return p.slice(idx + 1);
      }
      return '';
    };
  };
})();
`;

function installHostObjectImpls() {
  // ⚠️ **必须在 vm 里注入**（`source` / `cookie` 的壳只在 vm 里）⭐⭐⭐
  try {
    vm.runInContext(HOST_OBJECT_SHIM, ctx);
    vm.runInContext('__qrInstallHostObjects();', ctx);
  } catch (e) { /* 装不上 ⇒ 宿主对象仍是「调宿主」版（⇒ 返回 undefined） */ }
}

ctx.__qrAjax = function(url, optionsJSON) {
  var u = String(url === undefined ? '' : url);
  ctx.__qrRequests.push(u);
  var bare = u.split('?')[0];
  for (var i = 0; i < ctx.__qrRoutes.length; i++) {
    var r = ctx.__qrRoutes[i];
    if (bare.indexOf(r.match) >= 0 || u.indexOf(r.match) >= 0) {
      // ⚠️⭐⭐ **非 2xx ⇒ 返回「带原因的串」**（与 Swift 侧 `SourceEngine.ajax` 同语义）⭐⭐⭐
      //   ⇒ 站方 `JSON.parse(正文)` 抛 ⇒ **catch 换线** ⇒ 与真机一致 ⭐⭐⭐
      if (r.status < 200 || r.status >= 300) {
        return '请求失败(' + r.status + '): ' + u;
      }
      return r.body === undefined || r.body === null ? '' : String(r.body);
    }
  }
  return '请求失败(404): ' + u;
};

ctx.__hostJSON = function(object, method, argsJSON) {
  // ① ⭐ 纯计算方法 ⇒ JS 侧直接算（**有参数也能算**）⭐⭐⭐
  if (object === 'java' && ctx.__qrPure[method]) {
    let args = [];
    try { args = JSON.parse(argsJSON); } catch (e) { args = []; }
    const v = ctx.__qrPure[method].apply(null, args);
    return JSON.stringify([v === undefined ? null : v]);
  }
  // ⭐⭐⭐ **`java.ajax` 走【静态路由】**（同步 ⇒ 站方换线逻辑能跑）
  if (object === 'java' && method === 'ajax' && ctx.__qrRoutes.length > 0) {
    let a = [];
    try { a = JSON.parse(argsJSON); } catch (e) { a = []; }
    const v = ctx.__qrAjax(a[0], a[1]);
    return JSON.stringify([v === undefined ? null : v]);
  }
  // ⭐⭐⭐⭐⭐ **`java.startBrowserAwait` 等浏览器类** ⇒ 假浏览器（同步）⭐⭐⭐⭐⭐
  if (object === 'java' && (method === 'startBrowserAwait' || method === 'startBrowser'
      || method === 'showBrowser' || method === 'startBrowserDp' || method === 'showReadingBrowser')) {
    var ba = [];
    try { ba = JSON.parse(argsJSON); } catch (e) { ba = []; }
    var bu = String(ba[0] === undefined ? '' : ba[0]);
    ctx.__qrBrowsers.push(bu);
    for (var bi = 0; bi < ctx.__qrBrowserPages.length; bi++) {
      var bp = ctx.__qrBrowserPages[bi];
      if (bu.indexOf(String(bp.match || '')) >= 0) {
        // ⭐ **浏览器里登出来的 cookie ⇒ 合并回 cookie 罐**（宿主干的活 ⇒ 真机上是 HTTPCookieStorage）⭐
        if (bp.cookies) {
          var jar = ctx.__qrHostState.cookie.jar || (ctx.__qrHostState.cookie.jar = {});
          for (var bk in bp.cookies) {
            if (Object.prototype.hasOwnProperty.call(bp.cookies, bk)) jar[bk] = String(bp.cookies[bk]);
          }
        }
        return JSON.stringify([bp.html === undefined || bp.html === null ? '' : String(bp.html)]);
      }
    }
    return JSON.stringify(['']);
  }
  // ② 预置缓存（Swift 侧算好的）
  const key = object + '|' + method + '|' + argsJSON;
  if (Object.prototype.hasOwnProperty.call(ctx.__hostCache, key)) {
    return ctx.__hostCache[key];
  }
  // ⚠️ 缓存里没有 ⇒ **宿主没实现**（老引擎上也会是 undefined）⇒ 返回 null
  return 'null';
};

// ⭐⭐⭐ **读 stdin 必须用 readline（异步）** —— 2026-10-25 踩过
//   ⚠️ `fs.readSync(0, …)` 在**管道**里会阻塞/返回 0 ⇒ 读不到任何命令
//   ⇒ 表现为「node 一直不回复」⇒ Swift 侧超时 ⇒ 静默失败 ⭐⭐⭐
//   ⇒ readline 是行驱动的 ⇒ 正好匹配「一行一个 JSON」的协议 ⭐⭐⭐
const readline = require('readline');
const rl = readline.createInterface({ input: process.stdin, terminal: false });

function globals() {
  try { return Object.keys(ctx); } catch (e) { return []; }
}

// ⭐⭐⭐⭐⭐ **宿主对象壳**（与 JSCExecutor 的 `makeContext` 同款）
//   ⇒ `var source={},book={},chapter={},cookie={},cache={},java={};`
//   ⇒ **包装函数是挂在这些对象上的**（`java.hexDecodeToString = …`）
//   ⇒ 不先建壳 ⇒ 包装函数注入失败 ⇒ `java.xxx` 是 undefined ⇒ **规则静默失效** ⭐⭐⭐
function initHostShells() {
  try {
    vm.runInContext(
      'var source={},book={},chapter={},cookie={},cache={},java={};'
      // ⭐⭐⭐ **window 别名**（真机的 JSC 里 `window` 就是全局）
      //   ⇒ 站方/门禁常用 `window.java.xxx(...)` ⇒ 没有 window ⇒ undefined ⇒ 规则静默失效 ⭐⭐⭐
      + 'var window = globalThis;', ctx);
  } catch (e) { /* 建壳失败 ⇒ 包装函数会失败 ⇒ 记到全局错误里 */ }
}

function injectCompat(sources) {
  for (const src of (sources || [])) {
    try { vm.runInContext('(0, eval)(' + JSON.stringify(src) + ')', ctx); }
    catch (e) { /* 兼容层失败不致命（跟 JSC 一致） */ }
  }
}

function injectWrappers(sources) {
  for (const src of (sources || [])) {
    try { vm.runInContext('(0, eval)(' + JSON.stringify(src) + ')', ctx); }
    catch (e) { /* 包装函数失败 ⇒ 记到全局错误里 */ }
  }
}

function setHostProps(props, cache) {
  ctx.__hostCache = ctx.__hostCache || {};
  if (cache) { for (const [k, v] of Object.entries(cache)) { ctx.__hostCache[k] = v; } }
  for (const [name, objProps] of Object.entries(props || {})) {
    if (!ctx[name]) { ctx[name] = {}; }
    for (const [k, v] of Object.entries(objProps)) {
      try { ctx[name][k] = v; } catch (e) {}
    }
  }
}

function runEval(code, scope) {
  // ⭐⭐⭐⭐⭐ **三级兜底**（2026-10-25 真机实证）
  // ① **函数体形态** ⇒ 顶层 `return` 合法（站方真的这么写）
  // ② **Script 形态** ⇒ 末行表达式的完成值（Legado 的主语义）
  // ③ **整段当表达式** `(<code>)` ⇒ 对象字面量当规则时能用（老引擎/栖阅同款）⭐⭐⭐
  // ⇒ **谁先出值用谁**；①抛错 ⇒ 记下来，继续试 ②③ ⭐⭐⭐
  // ⭐⭐⭐⭐⭐ **scope 后面必须补分号**（2026-10-25 真 bug，Node 后端）
  //
  // ⚠️ **原来的 bug**：scope 和 code 之间只隔了一个换行
  //   ⇒ scope 是 `var book={},source={};` 这种**声明**（末尾**可能没有分号**）
  //   ⇒ 声明后面直接跟 `(function(){…})()` ⇒ **ASI 不会插入分号**
  //   ⇒ 语法错 ⇒ 第一级兜底直接炸 ⇒ **整条规则死** ⭐⭐⭐
  //   ⇒ 症状：Node JS 报错 "Unexpected token '('" / "Unexpected token 'var'" ⭐⭐⭐
  //
  // ⭐ 修法：scope 后补 `;` ⇒ 声明与后续代码彻底断开 ⭐⭐⭐
  const sc = (scope || '').replace(/\s*$/, '') + ';\n';

  // ⭐⭐⭐⭐⭐ **只执行一次（或两次）的形态选择**（2026-10-25 真 bug）
  //
  // ⚠️⚠️⚠️ **原来的 bug**：三级兜底是「**跑到有值为止**」
  //   ⇒ 第一级（函数体形态）执行完**没有值**（站方是末行表达式风格 ⇒ 函数体里没 return）
  //   ⇒ **继续跑第二级、第三级** ⇒ **站方 JS 被执行 3 次**！⭐⭐⭐
  //   ⇒ ⇒ 站方的 `java.ajax` 被调 **3 次** ⇒ **请求翻 3 倍** ⇒ 限流打爆（番茄 3 次/天）⭐⭐⭐
  //   ⇒ **真机（JSC）没有这个问题**（JSC 只 eval 一次）⇒ **沙盒 ≠ 真机** ⭐⭐⭐
  //   ⇒ ⇒ 门禁跑出来的是假象 ⇒ 也会掩盖真机的 bug ⭐⭐⭐
  //
  // ⭐⭐⭐ **正解**：**静态选形态** ⇒ 正常只跑一次
  //   ① 代码**首尾是 `{ }`** ⇒ 对象字面量 ⇒ 直接用「整段当表达式」
  //   ② 代码里有**顶层 return** ⇒ 用「函数体形态」（顶层 return 才合法）
  //   ③ 否则 ⇒ 用「Script 形态」（末行表达式的完成值）⭐⭐⭐
  //   ⇒ **只有真的抛语法错时**才追加一次「整段当表达式」⇒ 副作用最多 2 次（且只在语法错时）⭐⭐⭐
  const trimmed = String(code || '').trim();
  // ⭐⭐⭐ **对象字面量**（首尾 `{ }`）⇒ 直接用「整段当表达式」（**只跑一次**）
  //   （Script 形态会把 `{a:1}` 当**语句块** ⇒ 不抛错但返回 undefined ⇒ 拿不到值）⭐⭐⭐
  const isObjectLiteral = trimmed.charAt(0) === '{' && trimmed.charAt(trimmed.length - 1) === '}';

  // ⭐⭐⭐⭐⭐ **形态顺序（2026-10-25 定稿）**
  //
  // ① **对象字面量** ⇒ 「整段当表达式」⇒ 只跑一次 ⭐⭐⭐
  // ② **其它** ⇒ 先「Script 形态」（末行表达式的完成值 = Legado 主语义）⭐⭐⭐
  //    ⇒ **只有抛语法错**（顶层 `return` 在 Script 里是非法 return ⇒ SyntaxError）
  //      ⇒ 才改用「函数体形态」（顶层 return 才合法）⭐⭐⭐
  //    ⇒ ⚠️ **不要静态判断「有没有顶层 return」** ⇒ `(function(){return [];})()`
  //      这种**函数体内的 return** 会被误判 ⇒ 整条规则死 ⭐⭐⭐
  // ③ 追加「整段当表达式」（对象字面量之外的怪写法）
  //
  // ⭐⭐⭐ **副作用只发生一次**（形态 ① 一次 / 形态 ② 正常一次、
  //   **只有语法错**才再跑一次）⇒ 站方 `java.ajax` 不会被重复调 ⭐⭐⭐
  let attempts;
  if (isObjectLiteral) {
    attempts = [sc + '( ' + trimmed + '\n)'];
  } else {
    // ⭐⭐⭐⭐⭐ **Script 形态要包一层【块】**（2026-10-26 门禁迁移时补）
    //
    // ⚠️⚠️⚠️ **为什么必须**：Node 的 `vm.runInContext` 在**同一个 context** 里跑
    //   ⇒ 顶层的 `let` / `const` 会**留在 context 的词法作用域**里 ⇒
    //   ⇒ **第二次跑同样的代码 ⇒ 「Identifier 'x' has already been declared」** ⭐⭐⭐
    //   ⇒ 真书源（🍅大灰狼）的规则**每条都用了 `let`** ⇒
    //   ⇒ 第一条规则跑完 ⇒ **后面的规则全炸** ⇒ 详情页的 tocUrl / 目录 / 正文全废 ⭐⭐⭐
    //   ⇒ JSC 那边是「函数作用域里 eval」⇒ 每次都是新的词法作用域 ⇒ **没有这个问题** ⭐⭐⭐
    //   ⇒ ⇒ **这里包块**（块的完成值 = 块内最后一条语句的完成值 ⇒ Script 语义不变）⭐⭐⭐
    attempts = [sc + '{\n' + trimmed + '\n}', sc + '(function(){\n' + trimmed + '\n})()'];
  }

  let firstErr = null;
  const errs = [];
  for (let i = 0; i < attempts.length; i++) {
    let v = null, err = null;
    try { v = vm.runInContext(attempts[i], ctx); } catch (e) { err = e; }
    if (err) {
      errs.push('#' + (i + 1) + ': ' + String(err && err.message || err));
      if (!firstErr) firstErr = err;
      continue;
    }
    // ⭐⭐⭐ **执行成功就返回**（哪怕是 undefined/null）⇒ **不重复执行** ⭐⭐⭐
    if (v === undefined || v === null) {
      // ⭐⭐⭐⭐⭐ **这里【不许】再执行任何形态**（2026-10-26 真机回归实证）
      //
      // ⚠️⚠️ **原来的 bug**：undefined 时又跑了一次「整段当表达式」
      //   ⇒ **站方 JS 被执行 3 次** ⇒ `java.ajax` 调 3 次 ⇒ **限流打爆**
      //   ⇒ 日志写 3 倍 ⇒ **写盘翻倍** ⇒ 撞 iOS diskwrites 限额 ⇒ 被杀 ⭐⭐⭐
      //   ⇒ 而且 JSC 侧已经改成「undefined 就结束」⇒ **两边不一致** ⇒ 沙盒 ≠ 真机 ⭐⭐⭐
      //
      // ⭐ **正解**：形态选择已经在上面**静态定好**（对象字面量 ⇒ 整段当表达式；
      //   其它 ⇒ Script 优先、语法错才换函数体形态）⇒ **undefined 就是最终结果**
      //   ⇒ **不再执行** ⇒ 与 JSC 侧**逐字一致** ⭐⭐⭐
      //
      // ⭐⭐⭐⭐⭐ **「形态 1 抛错 + 形态 2 没值」⇒ 要把【真错】抛出去**（2026-10-26 门禁迁移时补）
      //
      // ⚠️⚠️⚠️ **为什么必须**：形态 1（Script）抛错、形态 2（函数体）返回 undefined 时
      //   ⇒ 以前这里 `return null` ⇒ **真错被吞掉** ⇒ Swift 侧只看到「规则求值为空」
      //   ⇒ **诊断在说谎**（引擎自己的纪律：诊断必须说真话）⭐⭐⭐
      //   ⇒ 症状：站方 JS 里的 `const { source } = this;`（顶层 `this` 在严格模式下是 undefined）
      //     ⇒ 真错是「Cannot destructure property 'source' of 'this'」
      //     ⇒ 但诊断只说「规则求值为空」⇒ **排查方向完全错** ⭐⭐⭐
      if (firstErr) {
        throw new Error(String(firstErr && firstErr.message || firstErr)
          + ' | 形态尝试: ' + errs.join(' || '));
      }
      return null;
    }
    return v;
  }
  // 全都抛错 ⇒ 把错误抛出去（让 Swift 侧知道「语法错」）
  // ⭐⭐⭐ **带上各级错误**（否则只看到最后一个 ⇒ 定位不到真凶）⭐⭐⭐
  if (firstErr) {
    const e = new Error(String(firstErr && firstErr.message || firstErr)
      + ' | 形态尝试: ' + errs.join(' || '));
    throw e;
  }
  return null;
}

function runGlobal(code) {
  const v = vm.runInContext('(0, eval)(' + JSON.stringify(code) + ')', ctx);
  return v === undefined ? null : v;
}

// ⭐⭐⭐ **stdin 关闭时【不要】退出** —— Swift 侧会先发 `quit` 再关管道
//   ⚠️ 若这里直接退出 ⇒ node 提前死 ⇒ Swift 侧再写 stdin ⇒ **SIGPIPE（signal 13）**⭐⭐⭐
rl.on('close', function() { /* 等 Swift 发 quit */ });

rl.on('line', function(line) {
  if (!line.trim()) return;
  let req;
  try { req = JSON.parse(line); } catch (e) { return; }
  try {
    if (req.cmd === 'init') {
      initHostShells();
      injectCompat(req.compat);
      injectWrappers(req.wrappers);
      // ⭐⭐⭐ **宿主对象的实现**（覆盖包装函数 ⇒ Node 侧查快照，不回调 Swift）⭐⭐⭐
      installHostObjectImpls();
      process.stdout.write(JSON.stringify({ ok: true }) + '\n');
    } else if (req.cmd === 'hostState') {
      // ⭐⭐⭐ **宿主对象的状态**：Swift 灌进来（读）/ 取回去（写）⭐⭐⭐
      if (req.state) {
        ctx.__qrHostState = req.state;
        // ⚠️ 状态换了 ⇒ **实现要重新装一遍**（闭包捕获的是旧状态对象）⭐
        installHostObjectImpls();
      }
      process.stdout.write(JSON.stringify({ ok: true, state: ctx.__qrHostState }) + '\n');
    } else if (req.cmd === 'runGlobal') {
      const v = runGlobal(req.code);
      process.stdout.write(JSON.stringify({ ok: true, value: v, globals: globals() }) + '\n');
    } else if (req.cmd === 'run') {
      setHostProps(req.hostProps, req.hostCache);
      const v = runEval(req.code, req.scope);
      process.stdout.write(JSON.stringify({ ok: true, value: v, globals: globals() }) + '\n');
    } else if (req.cmd === 'routes') {
      ctx.__qrRoutes = req.routes || [];
      process.stdout.write(JSON.stringify({ ok: true }) + '\n');
    } else if (req.cmd === 'browserPages') {
      ctx.__qrBrowserPages = req.pages || [];
      process.stdout.write(JSON.stringify({ ok: true }) + '\n');
    } else if (req.cmd === 'browsers') {
      process.stdout.write(JSON.stringify({ ok: true, browsers: ctx.__qrBrowsers || [] }) + '\n');
    } else if (req.cmd === 'requests') {
      process.stdout.write(JSON.stringify({ ok: true, requests: ctx.__qrRequests || [] }) + '\n');
    } else if (req.cmd === 'globals') {
      process.stdout.write(JSON.stringify({ ok: true, globals: globals() }) + '\n');
    } else if (req.cmd === 'invalidate') {
      process.stdout.write(JSON.stringify({ ok: true }) + '\n');
    } else if (req.cmd === 'quit') {
      process.stdout.write(JSON.stringify({ ok: true }) + '\n');
      process.exit(0);
    } else {
      process.stdout.write(JSON.stringify({ ok: false, error: 'unknown cmd' }) + '\n');
    }
  } catch (e) {
    process.stdout.write(JSON.stringify({ ok: false, error: String(e && e.message || e) }) + '\n');
  }
});
"""#
}

#else   // ⭐⭐⭐ 非 Linux（iOS / macOS）：只留 stub ⇒ 引用方不用改

/// ⭐⭐⭐ **非 Linux 上的 stub**（Node 后端不可用 ⇒ 沙盒那条路在 iOS/macOS 上不存在）
public final class NodeJSExecutor: JSExecutor, @unchecked Sendable {
    /// ⭐ **永远 false**（iOS/macOS 走 JavaScriptCore）
    public static var isAvailable: Bool { false }

    public init() throws {
        throw SourceError.unsupported("Node 后端只在 Linux 沙盒可用（iOS/macOS 走 JavaScriptCore）")
    }

    public func run(_ code: String, context: JSRunContext) throws -> JSONValue {
        throw SourceError.unsupported("Node 后端只在 Linux 沙盒可用")
    }
    public func runGlobal(_ code: String, context: JSRunContext) throws -> JSONValue {
        throw SourceError.unsupported("Node 后端只在 Linux 沙盒可用")
    }
    public func setEngineAPI(_ handler: JSEngineAPIHandler?) {}
    public func markGlobalsAsBaseline() {}
    public func invalidate() {}
}

#endif
