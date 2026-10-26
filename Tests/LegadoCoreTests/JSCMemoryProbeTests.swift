#if canImport(JavaScriptCore)
import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **JSC 内存探针**（2026-10-26 jetsam 6.8GB 实证）
///
/// ⚠️⚠️⚠️ **为什么必须有这个探针**：
///   真机（iOS · JavaScriptCore）上，某个 op 一次把 App 进程撑到 **11.7GB**
///   ⇒ **jetsam 杀进程** ⇒ 表现为「闪退」+ **没有 .ips** ⭐⭐⭐
///   ⇒ 而**沙盒（Linux · Node 后端）跑同样的 op 只涨 37MB** ⇒ **复现不了** ⭐⭐⭐
///   ⇒ ⇒ **只有 macOS 的 JSC 能验** ⇒ 本测试就是那个探针（引擎仓库的 `jsc` job 会跑它）⭐⭐⭐
///
/// ⭐⭐⭐ **它钉住的事**：
///   ① 每一步（jsLib 加载 / 分类 / 书单）之后的 **phys_footprint**（jetsam 同一个口径）
///      ⇒ **哪一步炸的，一眼可见**（CI 日志里）⭐⭐⭐
///   ② **放大比**：站方真实响应只有 13.6KB（书单）/ 74.7KB（分类）
///      ⇒ 如果 footprint 涨到几百 MB ⇒ **引擎里有 20 万倍放大** ⭐⭐⭐⭐⭐
///   ③ **门禁**：footprint 超过预算 ⇒ **红** ⇒ 以后这类回归会被拦住 ⭐⭐⭐
///
/// ⚠️ **为什么用假服务器**：真站方的响应**已经存成 fixture** ⇒
///   ⇒ ① 稳定可复现（站方改版不会影响这个探针）② CI 不依赖外网 ⭐⭐⭐
final class JSCMemoryProbeTests: XCTestCase {

    final class FixtureTransport: HTTPTransport, @unchecked Sendable {
        struct Route { let pattern: String; let file: String }
        private let routes: [Route]
        private let dir: URL
        private let lock = NSLock()
        private var _requested: [String] = []
        init(dir: URL, routes: [Route]) { self.dir = dir; self.routes = routes }
        var requested: [String] {
            lock.lock(); defer { lock.unlock() }
            return _requested
        }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            lock.lock(); _requested.append(request.url); lock.unlock()
            for r in routes where request.url.contains(r.pattern) {
                let data = try Data(contentsOf: dir.appendingPathComponent(r.file))
                return HTTPResponse(statusCode: 200, headers: [:], body: data, finalURL: request.url)
            }
            throw SourceError.requestFailed(request.url, "fixture 里没有这个 URL")
        }
    }

    /// ⭐ 假宿主（引擎只需要 `java.ajax` 走我们自己的桥）
    final class ProbeAPI: JSHostAPIProvider, @unchecked Sendable {
        /// ⭐ 引擎建好后回填 ⇒ 探针能拿到**真的** `source` 宿主对象
        ///   （App 侧 `EngineHostAPI` 就是这么给的 ⇒ 缺了它站方 JS 会报
        ///   「source.getVariable is not a function」⇒ 上一版探针就死在这）⭐⭐⭐
        weak var engineRef: SourceEngine?
        func hostObject(named name: String) -> HostObject? {
            if name == "source" { return engineRef?.sourceObject }
            // ⭐ 站方 exploreUrl 还会调 `cookie.getCookie()` ⇒ 缺它就抛
            //   「cookie.getCookie is not a function」⇒ 探针跑不到真路径 ⭐⭐⭐
            if name == "cookie" { return engineRef?.cookieObject }
            return nil
        }
        func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? { nil }
    }

    private static let fixtureDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LegadoCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 项目根
            .appendingPathComponent("conformance/fixtures/mem")
    }()

    /// ⭐⭐⭐ **footprint**（jetsam 判杀用的同一个口径，不是 resident_size）
    static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { r in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), r, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let f = Int(info.phys_footprint)
        return f > 0 ? f : Int(info.resident_size)
    }

    /// ⭐⭐⭐ **预算 = 相对基线的增量**（超了 ⇒ 红）
    /// ⚠️ 测试进程本身基线就有 170MB ⇒ 只能看**增量** ⭐⭐⭐
    /// 站在 74KB 响应上 ⇒ 增量应该是「几 MB 级」⇒ 给 **200MB** 的 generous 上限
    /// ⇒ 真出现 20 万倍放大时（增量几百 MB~GB）⇒ 必红 ⭐⭐⭐
    static let budgetDeltaMB = 200

    func testMemoryFootprintPerOp() throws {
        let dir = Self.fixtureDir
        let sourceData = try Data(contentsOf: dir.appendingPathComponent("dahuanglang.json"))
        let source = try JSONDecoder().decode(BookSource.self, from: sourceData)
        let transport = FixtureTransport(dir: dir, routes: [
            .init(pattern: "/discovestyle", file: "resp-kinds.txt"),
            .init(pattern: "/get_discover", file: "resp-books.txt"),
        ])
        // ⭐⭐⭐ **必须挂 JS 后端**（JSC）—— 站方的规则全是 JS ⭐⭐⭐
        //   ⇒ 引擎的 `java.ajax` 走 `setEngineAPI` 的桥 ⇒ 打到假服务器 ⭐⭐⭐
        let api = ProbeAPI()
        let exec = JSCExecutor(api: api)
        exec.setEngineAPI { method, args, _ in
            guard method == "ajax" else { return nil }
            var req = HTTPRequest(url: args.first?.scalarString ?? "", method: "GET")
            if let o = args.count > 1 ? args[1] : nil, case .object(let oo) = o {
                if let m = oo["method"]?.scalarString { req.method = m.uppercased() }
                if let b = oo["body"], !b.isNull { req.body = Data(b.scalarString.utf8) }
            }
            guard let resp = try? transport.send(req) else { return nil }
            return .string(String(data: resp.body, encoding: .utf8) ?? "")
        }
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport), js: exec,
                                  cookies: MemoryCookieService())
        api.engineRef = engine      // ⭐ 回填 ⇒ 站方 JS 能用 `source.getVariable()`

        func mb() -> Int { Self.footprintBytes() / (1024 * 1024) }
        func mark(_ label: String) -> Int {
            let m = mb()
            NSLog("JSC-MEM-PROBE %@ => footprint %d MB", label, m)
            return m
        }

        let base = mark("① 基线（引擎刚建）")

        // ② 加载站方 jsLib（真站方的 32KB jsLib）
        let srcDict = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any] ?? [:]
        if let lib = srcDict["jsLib"] as? String, !lib.isEmpty {
            try engine.loadJsLib(lib)
        }
        let afterLib = mark("② 加载站方 jsLib 后")
        XCTAssertNoThrow(try engine.sourceVars(), "站方默认变量表取不到 ⇒ 探针环境不对")
        XCTAssertLessThan(afterLib - base, Self.budgetDeltaMB,
                          "加载 jsLib 就涨了 \(afterLib - base) MB ⇒ **jsLib 加载有放大**")

        // ⭐⭐⭐ **站方的默认变量表要灌进 varBox**（App 侧 `seedVars` 干的就是这件事）
        //   ⇒ 不灌 ⇒ 站方 `getArguments` 拿不到 `server` ⇒ 分类请求发不出去 ⭐⭐⭐
        let vars = try engine.sourceVars()
        for (k, v) in vars { engine.varBox.set(k, v) }
        mark("②b 灌入站方默认变量表（\(vars.count) 项）后")

        // ③ 分类（站方 exploreUrl ⇒ 74.7KB 的响应 ⇒ 355 个分类）
        // ⭐⭐⭐ **不许 `try?` 吞异常** ⇒ 没跑出分类就是「探针没生效」⇒ 必须红 ⭐⭐⭐
        let kindsAll = try engine.exploreKinds().kinds
        let kinds = kindsAll.count
        XCTAssertGreaterThan(kinds, 0, "探针没跑出分类 ⇒ 探针本身失效了（不是内存没问题）")
        let afterKinds = mark("③ exploreKinds 后（\(kinds) 个分类）")
        XCTAssertLessThan(afterKinds - base, Self.budgetDeltaMB,
                          "分类这一步涨了 \(afterKinds - base) MB ⇒ **放大点在「响应 → 分类对象」**")

        // ④ 书单（13.6KB 的响应 ⇒ 27 本）
        //   ⚠️ **结果必须【留着】**（像 App 的缓存那样）⇒ 否则量不到「结果拽住内存」⭐⭐⭐
        let target = try XCTUnwrap(kindsAll.first { String($0.url).contains("get_discover") },
                                  "应有一个 get_discover 分类")
        let booksAll = try engine.explore(target.url)
        let books = booksAll.count
        XCTAssertGreaterThan(books, 0, "探针没跑出书单 ⇒ 探针本身失效了")
        let afterBooks = mark("④ explore 后（\(books) 本）")
        XCTAssertLessThan(afterBooks - base, Self.budgetDeltaMB,
                          "书单这一步涨了 \(afterBooks - base) MB ⇒ **放大点在「响应 → 书对象」**")

        // ⭐ 把结果**留在内存里**（别被优化掉）⇒ 最后再测一次「结果还活着时的水位」
        let afterHold = mark("⑤ 结果仍被持有时")
        XCTAssertLessThan(afterHold - base, Self.budgetDeltaMB,
                          "结果还活着就涨了 \(afterHold - base) MB ⇒ **结果拽住了内存**")
        print("⭐ [JSC 内存探针] 全部步骤的增量都在 \(Self.budgetDeltaMB) MB 以内 ⇒ 没有放大")
    }
}
#endif
