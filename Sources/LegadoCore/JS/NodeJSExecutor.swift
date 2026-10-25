import Foundation

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
                      "wrappers": JSScopeBuilder.hostWrappers()])
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
        let cache = Self.pureMethodCache(engineAPI: engineAPI, base: currentBase)
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
                                        base: RuleBase) -> [String: String] {
        guard let engineAPI else { return [:] }
        var out: [String: String] = [:]
        // ⭐ 站方包装函数的调用形态：`__hostJSON('java','base64Encode', JSON.stringify([args…]))`
        //   ⇒ 缓存 key 用**同样形态** ⇒ Node 侧查表能命中 ⭐⭐⭐
        for method in ["base64Encode", "base64Decode", "md5Encode", "timeFormat",
                       "hexDecodeToString", "hexEncodeToString", "base64DecodeSafe"] {
            guard let r = engineAPI(method, [], base) else { continue }
            let any = r.foundationValue
            guard let data = try? JSONSerialization.data(withJSONObject: [any]),
                  let text = String(data: data, encoding: .utf8) else { continue }
            out["java|\(method)|[]"] = text
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
  base64Decode: function(s) {
    try { return Buffer.from(String(s), 'base64').toString('utf8'); } catch (e) { return ''; }
  },
  md5Encode: function(s) {
    return require('crypto').createHash('md5')
      .update(String(s === undefined ? '' : s), 'utf8').digest('hex');
  },
  hexDecodeToString: function(s) {
    const t = String(s === undefined ? '' : s);
    if (!/^[0-9a-fA-F]*$/.test(t)) return '';
    let out = '';
    for (let i = 0; i + 1 < t.length; i += 2) {
      out += String.fromCharCode(parseInt(t.slice(i, i + 2), 16));
    }
    return out;
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

ctx.__hostJSON = function(object, method, argsJSON) {
  // ① ⭐ 纯计算方法 ⇒ JS 侧直接算（**有参数也能算**）⭐⭐⭐
  if (object === 'java' && ctx.__qrPure[method]) {
    let args = [];
    try { args = JSON.parse(argsJSON); } catch (e) { args = []; }
    const v = ctx.__qrPure[method].apply(null, args);
    return JSON.stringify([v === undefined ? null : v]);
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
  const attempts = [
    (scope || '') + '\n' + '(function(){\n' + code + '\n})()',
    (scope || '') + '\n' + code,
    (scope || '') + '\n' + '( ' + code + '\n)',
  ];
  let firstErr = null;
  for (let i = 0; i < attempts.length; i++) {
    let v = null, err = null;
    try { v = vm.runInContext(attempts[i], ctx); } catch (e) { err = e; }
    if (err) { if (!firstErr) firstErr = err; continue; }
    if (v !== undefined && v !== null) return v;
  }
  // 全都没值 ⇒ 若第一次是语法错 ⇒ **把它抛出去**（让 Swift 侧知道「语法错」）
  if (firstErr) throw firstErr;
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
      injectCompat(req.compat);
      injectWrappers(req.wrappers);
      process.stdout.write(JSON.stringify({ ok: true }) + '\n');
    } else if (req.cmd === 'runGlobal') {
      const v = runGlobal(req.code);
      process.stdout.write(JSON.stringify({ ok: true, value: v, globals: globals() }) + '\n');
    } else if (req.cmd === 'run') {
      setHostProps(req.hostProps, req.hostCache);
      const v = runEval(req.code, req.scope);
      process.stdout.write(JSON.stringify({ ok: true, value: v, globals: globals() }) + '\n');
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
