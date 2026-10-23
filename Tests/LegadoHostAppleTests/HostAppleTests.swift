import Foundation
import XCTest
@testable import LegadoCore
@testable import LegadoHostApple

/// ⭐ **宿主层参考实现的门禁**（纯 Foundation 部分 ⇒ **Linux 沙盒也能真编真跑**）
final class HostAppleTests: XCTestCase {

    // MARK: - ① UserDefaults 版键值存储

    func testUserDefaultsStorage() throws {
        let suite = "legado.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = UserDefaultsStorage(defaults: defaults, prefix: "src.a.")

        XCTAssertNil(storage.string(forKey: "k"))
        storage.setString("v", forKey: "k")
        XCTAssertEqual(storage.string(forKey: "k"), "v")
        XCTAssertEqual(storage.allKeys(), ["k"])
        // ⭐ 写 nil ⇒ 删除
        storage.setString(nil, forKey: "k")
        XCTAssertNil(storage.string(forKey: "k"))
    }

    /// ⭐⭐ **前缀隔离**（不同书源的变量不串台）
    func testUserDefaultsPrefixIsolation() throws {
        let suite = "legado.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = UserDefaultsStorage(defaults: defaults, prefix: "src.A.")
        let b = UserDefaultsStorage(defaults: defaults, prefix: "src.B.")
        a.setString("A值", forKey: "k")
        b.setString("B值", forKey: "k")
        XCTAssertEqual(a.string(forKey: "k"), "A值")
        XCTAssertEqual(b.string(forKey: "k"), "B值")
    }

    // MARK: - ② FileManager 版文件存储

    func testFileManagerStorage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legado-test-\(UUID().uuidString)")
        let storage = FileManagerStorage(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(storage.exists("a/b.txt"))
        try storage.write(Data("内容".utf8), to: "a/b.txt")
        XCTAssertTrue(storage.exists("a/b.txt"))
        XCTAssertEqual(try storage.read("a/b.txt"), Data("内容".utf8))
        XCTAssertEqual(try storage.list("a"), ["b.txt"])
        try storage.remove("a/b.txt")
        XCTAssertFalse(storage.exists("a/b.txt"))
    }

    /// ⭐⭐ **路径穿越必须挡住**（否则引擎一个规则就能读宿主任意文件）
    func testFileManagerStorageRejectsPathTraversal() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legado-test-\(UUID().uuidString)")
        let storage = FileManagerStorage(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try storage.read("../etc/passwd"))
        XCTAssertThrowsError(try storage.write(Data(), to: "/etc/passwd"))
        XCTAssertThrowsError(try storage.read("a/../../b"))
    }

    // MARK: - ③ 日志

    func testPrintLogger() {
        let logger = PrintLogger(keep: 3)
        logger.log("一")
        logger.log("二")
        logger.log("三")
        logger.log("四")   // 超出 keep ⇒ 丢最旧的
        XCTAssertEqual(logger.all, ["二", "三", "四"])
        logger.clear()
        XCTAssertTrue(logger.all.isEmpty)
    }
}
