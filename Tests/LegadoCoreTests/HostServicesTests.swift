import Foundation
import XCTest
@testable import LegadoCore

/// **宿主服务契约**门禁 —— 存储 / 文件 / 浏览器 / 提示 / 日志。
final class HostServicesTests: XCTestCase {

    // MARK: - ① 键值存储

    func testKeyValueStorage() {
        let s = MemoryStorage()
        XCTAssertNil(s.string(forKey: "a"))
        s.setString("1", forKey: "a")
        s.setString("2", forKey: "b")
        XCTAssertEqual(s.string(forKey: "a"), "1")
        XCTAssertEqual(s.allKeys(), ["a", "b"])
        s.setString(nil, forKey: "a")
        XCTAssertNil(s.string(forKey: "a"), "设 nil 应等于删除")
        s.removeValue(forKey: "b")
        XCTAssertTrue(s.allKeys().isEmpty)
    }

    // MARK: - ② 文件存储

    func testFileStorage() throws {
        let f = MemoryFileStorage()
        XCTAssertFalse(f.exists("a.txt"))
        XCTAssertThrowsError(try f.read("a.txt"), "读不存在的文件应抛错")
        try f.write(Data("hi".utf8), to: "cache/a.txt")
        XCTAssertTrue(f.exists("cache/a.txt"))
        XCTAssertEqual(String(data: try f.read("cache/a.txt"), encoding: .utf8), "hi")
        XCTAssertEqual(try f.list("cache"), ["a.txt"])
        try f.remove("cache/a.txt")
        XCTAssertFalse(f.exists("cache/a.txt"))
    }

    // MARK: - ③ 编排层接线（诊断 → 日志 / 错误 → 提示）

    /// 跑一遍端到端 ⇒ **日志里必须留下诊断**
    func testDiagnosticsGoToHostLogger() throws {
        let (engine, _) = try makeEngine(logger: RecordingLogger())
        let logger = engine.logger as? RecordingLogger
        XCTAssertNotNil(logger)
        _ = try engine.search("仙逍")
        XCTAssertFalse(logger!.all.isEmpty, "跑完流水线应留下日志")
        XCTAssertTrue(logger!.all.contains { $0.contains("分支=") || $0.contains("ok") },
                      "日志应是诊断的单行形式：\(logger!.all.prefix(3))")
    }

    /// 请求失败 ⇒ **提示要收到错误**
    func testRequestFailureNotifiesHost() throws {
        let source = try loadSource()
        let transport = FailingTransport()
        let notifier = RecordingNotifier()
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport),
                                  notifier: notifier)
        XCTAssertThrowsError(try engine.search("仙逍")) { error in
            guard case SourceError.requestFailed = error else {
                return XCTFail("应是请求失败，实际：\(error)")
            }
        }
        // ⭐ 编排层出错时**要先通知宿主**（用户看得见的 toast）⇒ 再把错误抛出去
        XCTAssertEqual(notifier.allErrors.count, 1, "应通知宿主一次：\(notifier.allErrors)")
        XCTAssertTrue(notifier.allErrors.first?.contains("请求失败") ?? false,
                      "提示内容要说清是网络层：\(notifier.allErrors)")
    }

    // MARK: - 工具

    private static let fixtureDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/e2e")
    }()

    private func loadSource() throws -> BookSource {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("source-eayue.json"))
        return try JSONDecoder().decode(BookSource.self, from: data)
    }

    private func makeEngine(logger: EngineLogger? = nil) throws -> (SourceEngine, Any) {
        final class T: HTTPTransport, @unchecked Sendable {
            let dir: URL
            init(dir: URL) { self.dir = dir }
            func send(_ request: HTTPRequest) throws -> HTTPResponse {
                if request.url.contains("/ta/search.m") {
                    let data = try Data(contentsOf: dir.appendingPathComponent("search.html"))
                    return HTTPResponse(statusCode: 200, headers: [:], body: data, finalURL: request.url)
                }
                throw SourceError.requestFailed(request.url, "没有这个 URL")
            }
        }
        let source = try loadSource()
        let transport = T(dir: Self.fixtureDir)
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport),
                                  logger: logger)
        return (engine, transport)
    }
}

/// 必定失败的传输
final class FailingTransport: HTTPTransport, @unchecked Sendable {
    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        throw SourceError.requestFailed(request.url, "测试用：必失败")
    }
}
