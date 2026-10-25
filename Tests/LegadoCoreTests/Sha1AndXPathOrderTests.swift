import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **2026-10-26 门禁迁移时补的两个回归门禁**
///
/// ① **SHA-1**（`java.sha1Encode`）
///    · 老引擎（轻阅 `Resources/engine/sha1.js`）**有** SHA-1
///    · 新引擎的宿主 API 清单里**写着** `java.sha1Encode`（`JSHostAPI.swift`）
///      ⇒ 但**没人实现** ⇒ 站方一调就 undefined ⇒ **静默失效** ⭐⭐⭐
///    ⇒ 补 `Crypto.sha1Hex` + `engineJava("sha1Encode")` + Node 后端的纯计算表 ⭐⭐⭐
///
/// ② **XPath 的结果顺序**
///    · XPath 1.0 规定结果集按**文档顺序**
///    · 老引擎（jsdom 的 `document.evaluate`）就是文档顺序
///    · 新引擎原来用「栈 + `popLast()`」⇒ **倒序** ⇒ **回归** ⭐⭐⭐
///    ⇒ 后果：站方规则里「取第一条 / 取全部」的顺序全反 ⇒ 目录章节倒序 ⭐⭐⭐
final class Sha1AndXPathOrderTests: XCTestCase {

    // MARK: - ① SHA-1（RFC 3174 官方测试向量）

    func testSHA1OfficialVectors() {
        let vectors: [(String, String)] = [
            ("", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
            ("abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "84983e441c3bd26ebaae4aa1f95129e5e54670f1"),
            (String(repeating: "a", count: 1000000),
             "34aa973cd4c4daa4f61eeb2bdbad27316534016f"),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(Crypto.sha1Hex(input), expected, "⭐ SHA1(\(input.prefix(20))) 不对")
        }
    }

    func testSHA1UsesUTF8Bytes() {
        XCTAssertEqual(Crypto.sha1Hex("中文").count, 40, "SHA1 恒为 40 位 hex")
        XCTAssertNotEqual(Crypto.sha1Hex("中文"), Crypto.sha1Hex("ab"))
    }

    // MARK: - ② XPath 文档顺序

    func testXPathResultsAreInDocumentOrder() {
        let html = "<html><body><ul><li>一</li><li>二</li><li>三</li></ul></body></html>"
        let doc = try! SwiftSoupDocument(html: html, baseURL: "https://x.example/")
        let r = XPathEngine.select(doc.document, "//li")
        let texts = (r ?? []).map { $0.text }
        XCTAssertEqual(texts, ["一", "二", "三"],
                       "⭐ XPath 必须按【文档顺序】返回（跟 document.evaluate 一致）")
    }

    func testXPathNestedResultsAreInDocumentOrder() {
        let html = "<html><body><div><p>a</p></div><div><p>b</p></div><div><p>c</p></div></body></html>"
        let doc = try! SwiftSoupDocument(html: html, baseURL: "https://x.example/")
        let r = XPathEngine.select(doc.document, "//p")
        let texts = (r ?? []).map { $0.text }
        XCTAssertEqual(texts, ["a", "b", "c"],
                       "⭐ XPath 跨层级也必须按【文档顺序】")
    }
}
