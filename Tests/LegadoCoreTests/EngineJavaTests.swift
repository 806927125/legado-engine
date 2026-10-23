import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **引擎侧 `java.*` 的门禁**（沙盒可跑，不碰 JSC）
///
/// 站方 JS 用的 API 里，**引擎能做的**那一批（125 源真实用量）：
/// | API | 处数 |
/// |---|---|
/// | `java.md5Encode` | **233** |
/// | `java.ajax` | 27 |
/// | `java.base64Decode` / `base64Encode` / `hexDecodeToString` | 7 / 5 / 3 |
/// | `java.randomUUID` | 2 |
/// | `java.toNumChapter` | 1 |
///
/// ⚠️ 这份门禁直接调 `SourceEngine.engineJava(...)` ⇒ Linux 沙盒能跑；
/// JSC 那层（JS 里真能调）由 `JSCAjaxTests`（macOS CI）验。
final class EngineJavaTests: XCTestCase {

    private func engine() throws -> SourceEngine {
        let data = Data("{\"bookSourceName\":\"x\",\"bookSourceUrl\":\"https://example.test\"}".utf8)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        return SourceEngine(source: source, fetcher: PageFetcher(transport: MemTransport()))
    }

    final class MemTransport: HTTPTransport, @unchecked Sendable {
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data("<html/>".utf8), finalURL: request.url)
        }
    }

    // MARK: - ① md5Encode（233 处 ⇒ 最多）

    /// ⭐⭐ **MD5 官方测试向量**（RFC 1321）
    func testMD5Encode() throws {
        let e = try engine()
        XCTAssertEqual(e.engineJava("md5Encode", [.string("")])?.scalarString,
                       "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(e.engineJava("md5Encode", [.string("abc")])?.scalarString,
                       "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(
            e.engineJava("md5Encode", [.string("12345678901234567890123456789012345678901234567890123456789012345678901234567890")])?.scalarString,
            "57edf4a22be3c955ac49da2e2107b67a")
    }

    // MARK: - ② base64 / hex

    func testBase64AndHex() throws {
        let e = try engine()
        XCTAssertEqual(e.engineJava("base64Encode", [.string("hello")])?.scalarString, "aGVsbG8=")
        XCTAssertEqual(e.engineJava("base64Decode", [.string("aGVsbG8=")])?.scalarString, "hello")
        // ⚠️ 解不了 ⇒ **空串**（不是 nil —— nil = 不接管）
        XCTAssertEqual(e.engineJava("base64Decode", [.string("!!!")])?.scalarString, "")
        // ⭐ hex 的双语义
        XCTAssertEqual(e.engineJava("hexDecodeToString", [.string("6d796466")])?.scalarString, "mydf")
        XCTAssertEqual(e.engineJava("hexDecodeToString", [.string("aGVsbG8=")])?.scalarString, "hello")
    }

    // MARK: - ③ randomUUID / toNumChapter

    func testRandomUUIDAndToNumChapter() throws {
        let e = try engine()
        let uuid = e.engineJava("randomUUID", [])?.scalarString ?? ""
        XCTAssertEqual(uuid.count, 36, "UUID 形状")
        // ⭐ 站方用法：整段文本里的中文数字要转掉
        XCTAssertEqual(e.engineJava("toNumChapter", [.string("第123章")])?.scalarString, "第123章")
        XCTAssertEqual(e.engineJava("toNumChapter", [.string("第三十五章开始")])?.scalarString, "第35章开始")
    }

    // MARK: - ④ ⭐ **不接管 ⇒ 返回 nil ⇒ 落回宿主**

    /// ⭐⭐ 这是**整个机制的关键**：引擎只抢它真做的那几个，其余仍归宿主
    func testUnimplementedMethodsAreNotIntercepted() throws {
        let e = try engine()
        XCTAssertNil(e.engineJava("toast", [.string("hi")]), "⭐ toast 归宿主，不该被引擎接管")
        XCTAssertNil(e.engineJava("log", [.string("hi")]))
        XCTAssertNil(e.engineJava("getCookie", [.string("k")]))
        XCTAssertNil(e.engineJava("startBrowser", [.string("u")]))
        XCTAssertNil(e.engineJava("someBrandNewApi", []))
    }
}
