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

    /// ⭐⭐⭐ **预算**（超了 ⇒ 红）
    /// 站在 74KB 响应上 ⇒ 正常应该是「几 MB 级」⇒ 给 **300MB** 的 generous 上限
    /// ⇒ 真出现 20 万倍放大时（GB 级）⇒ 必红 ⭐⭐⭐
    static let budgetMB = 300

    func testMemoryFootprintPerOp() throws {
        let dir = Self.fixtureDir
        let sourceData = try Data(contentsOf: dir.appendingPathComponent("dahuanglang.json"))
        let source = try JSONDecoder().decode(BookSource.self, from: sourceData)
        let transport = FixtureTransport(dir: dir, routes: [
            .init(pattern: "/discovestyle", file: "resp-kinds.txt"),
            .init(pattern: "/get_discover", file: "resp-books.txt"),
        ])
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))

        func mb() -> Int { Self.footprintBytes() / (1024 * 1024) }
        func mark(_ label: String) -> Int {
            let m = mb()
            print("⭐ [JSC 内存探针] \(label) ⇒ footprint \(m) MB")
            return m
        }

        let base = mark("① 基线（引擎刚建）")
        XCTAssertLessThan(base, Self.budgetMB, "基线就已经超预算了 ⇒ 环境不对")

        // ② 加载站方 jsLib（真站方的 32KB jsLib）
        let srcDict = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any] ?? [:]
        if let lib = srcDict["jsLib"] as? String, !lib.isEmpty {
            try engine.loadJsLib(lib)
        }
        let afterLib = mark("② 加载站方 jsLib 后")
        XCTAssertLessThan(afterLib, Self.budgetMB, "加载 jsLib 就把内存撑到 \(afterLib) MB ⇒ jsLib 加载有放大")

        // ③ 分类（站方 exploreUrl ⇒ 74.7KB 的响应 ⇒ 355 个分类）
        let kinds = (try? engine.exploreKinds().kinds.count) ?? 0
        let afterKinds = mark("③ exploreKinds 后（\(kinds) 个分类）")
        XCTAssertLessThan(afterKinds, Self.budgetMB,
                          "分类这一步就把内存撑到 \(afterKinds) MB ⇒ **放大点在「响应 → 分类对象」**")

        // ④ 书单（13.6KB 的响应 ⇒ 27 本）
        var books = 0
        if let url = (try? engine.exploreKinds().kinds.first?.url), !url.isEmpty {
            books = (try? engine.explore(url).count) ?? 0
        }
        let afterBooks = mark("④ explore 后（\(books) 本）")
        XCTAssertLessThan(afterBooks, Self.budgetMB,
                          "书单这一步就把内存撑到 \(afterBooks) MB ⇒ **放大点在「响应 → 书对象」**")

        print("⭐ [JSC 内存探针] 全部步骤的 footprint 都在 \(Self.budgetMB) MB 以内 ⇒ 没有放大")
    }
}
#endif
