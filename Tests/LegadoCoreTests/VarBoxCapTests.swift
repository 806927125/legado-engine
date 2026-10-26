import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **变量值封顶**（2026-10-26 jetsam 4.2GB 实证）
///
/// 站方把大块数据缓存进源变量 ⇒ 值涨到 GB 级 ⇒ 宿主回传时**好几份拷贝** ⇒ jetsam 秒杀
/// ⇒ **宿主必须给变量值封顶**（丢了缓存只是多抓一次，不会崩）⭐
final class VarBoxCapTests: XCTestCase {
    func testOversizedValueIsTruncated() throws {
        let box = VarBox()
        let huge = String(repeating: "x", count: VarBox.maxValueBytes * 3)
        box.set("big", huge)
        let stored = try XCTUnwrap(box.get("big"))
        XCTAssertLessThan(stored.utf8.count, VarBox.maxValueBytes,
                          "超大变量值必须被截断（否则回传时撑爆宿主进程）")
    }

    func testNormalValueIsKeptIntact() throws {
        let box = VarBox()
        box.set("k", "hello")
        XCTAssertEqual(try XCTUnwrap(box.get("k")), "hello", "正常值不许被截断")
    }
}
