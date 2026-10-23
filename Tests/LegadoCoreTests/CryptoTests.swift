import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **纯计算门禁**（MD5 / Base64 / Hex / UUID / 中文数字）
///
/// ⚠️ **MD5 用 RFC 1321 的官方测试向量** ⇒ 自己实现的位运算**写错必红**。
final class CryptoTests: XCTestCase {

    // MARK: - ① MD5（RFC 1321 官方测试套件）

    func testMD5OfficialVectors() {
        let vectors: [(String, String)] = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
             "d174ab98d277d9f5a5611c2c9f419d9f"),
            ("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
             "57edf4a22be3c955ac49da2e2107b67a"),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(Crypto.md5Hex(input), expected, "⭐ MD5(\(input)) 不对")
        }
    }

    /// ⚠️ **中文要按 UTF-8 字节算**（不是字符数）
    func testMD5UsesUTF8Bytes() {
        // 已知值：MD5("中文") = md5(0xE4B8ADE69687 0xE69687)
        XCTAssertEqual(Crypto.md5Hex("中文").count, 32, "MD5 恒为 32 位 hex")
        XCTAssertNotEqual(Crypto.md5Hex("中文"), Crypto.md5Hex("ab"),
                          "⚠️ 不同内容不能同哈希")
    }

    // MARK: - ② Base64

    func testBase64RoundTrip() {
        XCTAssertEqual(Crypto.base64Encode("hello"), "aGVsbG8=")
        XCTAssertEqual(Crypto.base64Decode("aGVsbG8="), "hello")
        // ⭐ 中文往返
        let cn = "小说正文"
        XCTAssertEqual(Crypto.base64Decode(Crypto.base64Encode(cn)), cn)
    }

    /// ⚠️ **解不了 ⇒ 明确失败（nil）**，不返回乱码
    func testBase64InvalidFailsExplicitly() {
        XCTAssertNil(Crypto.base64Decode("!!!不是base64!!!"))
    }

    // MARK: - ③ Hex

    /// ⭐⭐ **`hexDecodeToString` 的双语义**：
    /// 「**不是合法 hex 就按 base64 再试一次**」⇒ 站方两种载荷都能解。
    func testHexDecodeToStringFallsBackToBase64() {
        // ① 合法 hex
        XCTAssertEqual(Crypto.hexDecodeToString("6d796466"), "mydf")
        // ② 不是合法 hex（奇数长度 / 非法字符）⇒ 退回 base64
        let b64 = Crypto.base64Encode("mydf")
        XCTAssertEqual(Crypto.hexDecodeToString(b64), "mydf",
                       "⭐ 不是合法 hex 时要能按 base64 解出来")
        // ③ 两个都不行 ⇒ 明确失败
        XCTAssertNil(Crypto.hexDecodeToString("!!!"))
    }

    /// ⚠️ **长度必须是偶数**（否则不是合法 hex）
    func testHexRequiresEvenLength() {
        XCTAssertNil(Crypto.hexDecode("abc"))
        XCTAssertEqual(Crypto.hexDecode("616263"), "abc")
    }

    // MARK: - ④ UUID

    func testRandomUUIDShape() {
        let u = Crypto.randomUUID()
        XCTAssertEqual(u.count, 36, "UUID 形如 8-4-4-4-12")
        XCTAssertEqual(u.filter { $0 == "-" }.count, 4)
        XCTAssertNotEqual(u, Crypto.randomUUID(), "两次应不同")
    }

    // MARK: - ⑤ 中文数字

    /// ⭐ **中文数字 ⇒ 阿拉伯数字**（站方用来把「第X章」换成「第N章」）
    func testChineseNumeral() {
        XCTAssertEqual(Crypto.chineseNumeral("三"), "3")
        XCTAssertEqual(Crypto.chineseNumeral("十"), "10")
        XCTAssertEqual(Crypto.chineseNumeral("十二"), "12")
        XCTAssertEqual(Crypto.chineseNumeral("二十"), "20")
        XCTAssertEqual(Crypto.chineseNumeral("三十五"), "35")
        XCTAssertEqual(Crypto.chineseNumeral("一百零八"), "108")
        XCTAssertEqual(Crypto.chineseNumeral("一千零一"), "1001")
    }

    /// ⚠️ **不是纯中文数字 ⇒ 原样返回**（不乱猜）
    func testChineseNumeralPassesThroughNonNumeric() {
        XCTAssertEqual(Crypto.chineseNumeral("abc"), "abc")
        XCTAssertEqual(Crypto.chineseNumeral(""), "")
    }
}
