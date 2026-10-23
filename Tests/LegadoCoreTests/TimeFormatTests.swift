import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐ **时间格式化门禁**（`java.timeFormat` / `java.timeFormatUTC`，18 处用法）
///
/// **依据**：轻阅参考实现（`reference/js/java-api.js`）的注释 + 125 源真实用法
/// - `java.timeFormat(t)` ⇒ epoch 毫秒 → `"yyyy-MM-dd HH:mm:ss"`（本地时区）
/// - `java.timeFormatUTC(t, 'yyyy-MM-dd', 8)` ⇒ epoch 毫秒 + pattern + **时区偏移小时**
final class TimeFormatTests: XCTestCase {

    /// 2024-01-01 00:00:00 UTC
    private let epoch: Int64 = 1_704_067_200_000

    // MARK: - ① UTC 版（时区确定 ⇒ 可以断言确切值）

    /// ⭐⭐ **时区偏移**（站方传 `8` = UTC+8）
    func testTimeFormatUTCWithTimezone() {
        XCTAssertEqual(TimeFormat.format(millis: epoch, pattern: "yyyy-MM-dd",
                                         utcOffsetHours: 8), "2024-01-01",
                       "UTC+0 的那一刻在 UTC+8 仍是 1 月 1 日")
        XCTAssertEqual(TimeFormat.format(millis: epoch, pattern: "yyyy-MM-dd HH:mm:ss",
                                         utcOffsetHours: 8), "2024-01-01 08:00:00",
                       "⭐ UTC+8 ⇒ 加 8 小时")
        XCTAssertEqual(TimeFormat.format(millis: epoch, pattern: "yyyy-MM-dd HH:mm:ss",
                                         utcOffsetHours: 0), "2024-01-01 00:00:00",
                       "UTC+0")
    }

    /// ⚠️ **时区会跨日**：UTC 16:00 在 UTC+8 是第二天
    func testTimeFormatUTCCrossesDayBoundary() {
        let lateUTC: Int64 = 1_704_124_800_000   // 2024-01-01 16:00:00 UTC
        XCTAssertEqual(TimeFormat.format(millis: lateUTC, pattern: "yyyy-MM-dd",
                                         utcOffsetHours: 8), "2024-01-02",
                       "⭐ 跨日要算对")
    }

    // MARK: - ② ⭐ Java pattern **大小写敏感**

    /// ⚠️⚠️ **`MM` = 月、`mm` = 分**（和 `MM`/`mm` 混了就是错 100 倍）
    func testJavaPatternIsCaseSensitive() {
        let out = TimeFormat.format(millis: epoch, pattern: "yyyy-MM-dd HH:mm:ss",
                                    utcOffsetHours: 0)
        XCTAssertEqual(out, "2024-01-01 00:00:00")
        // 「月」在第 6-7 位，「分」在第 12-13 位 ⇒ 值不同
        XCTAssertTrue(out.hasPrefix("2024-01-01"), "月份段 = 01")
        XCTAssertTrue(out.hasSuffix("00:00:00"), "分钟段 = 00")
    }

    // MARK: - ③ 默认格式

    /// ⭐ **默认格式 = `"yyyy-MM-dd HH:mm:ss"`**
    func testDefaultPattern() {
        XCTAssertEqual(TimeFormat.defaultPattern, "yyyy-MM-dd HH:mm:ss")
        let out = TimeFormat.format(millis: epoch, utcOffsetHours: 0)
        XCTAssertEqual(out, "2024-01-01 00:00:00", "⭐ 默认格式")
    }

    // MARK: - ④ 毫秒 / 两位年

    func testOtherPatternFields() {
        XCTAssertEqual(TimeFormat.format(millis: epoch, pattern: "yy", utcOffsetHours: 0), "24")
        XCTAssertEqual(TimeFormat.format(millis: epoch, pattern: "SSS", utcOffsetHours: 0), "000")
    }

    // MARK: - ⑤ 入参解析

    /// ⭐ **纯数字 ⇒ 当毫秒**
    func testMillisParsing() {
        XCTAssertEqual(TimeFormat.millis(from: "1704067200000"), 1_704_067_200_000)
        XCTAssertNil(TimeFormat.millis(from: ""))
        XCTAssertNil(TimeFormat.millis(from: "   "))
    }

    /// ⭐ **日期串也能解析**（站方可能直接给 "2024-01-01 10:00:00"）
    func testDateStringParsing() {
        let ms = TimeFormat.millis(from: "2024-01-01 00:00:00")
        XCTAssertNotNil(ms, "常见日期格式应能解析")
    }

    // MARK: - ⑥ 引擎侧接线

    func testEngineJavaTimeFormat() throws {
        let data = Data("{\"bookSourceName\":\"x\",\"bookSourceUrl\":\"https://example.test\"}".utf8)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: T()))
        // ⭐ `timeFormatUTC(ms, 'yyyy-MM-dd', 8)`
        XCTAssertEqual(
            engine.engineJava("timeFormatUTC",
                              [.string("1704067200000"), .string("yyyy-MM-dd"), .int(8)],
                              .page(""))?.scalarString,
            "2024-01-01")
        // ⭐ `timeFormat(ms)` ⇒ 默认格式
        XCTAssertEqual(
            engine.engineJava("timeFormat", [.string("1704067200000")], .page(""))?.scalarString
                .count, 19, "默认格式长度 = yyyy-MM-dd HH:mm:ss")
        // ⚠️ 解析不了 ⇒ 空串（不是 nil —— nil = 不接管）
        XCTAssertEqual(engine.engineJava("timeFormat", [.string("不是时间")], .page(""))?.scalarString, "")
    }

    final class T: HTTPTransport, @unchecked Sendable {
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], body: Data(), finalURL: request.url)
        }
    }
}
