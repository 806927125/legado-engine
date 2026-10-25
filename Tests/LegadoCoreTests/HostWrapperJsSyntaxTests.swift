import XCTest
@testable import LegadoCore

/// ⭐⭐⭐ **生成的宿主包装函数 JS 必须语法有效**（2026-10-25 build248 真机事故）
///
/// **事故**：`java.longToast is not a function`（build248 仍然报）
/// ⇒ 真机错误是 **JSC 说的**（带 `In '…'` + `is undefined`）⇒ **属性压根不存在**
/// ⇒ 而引擎明明登记了 `longToast` ⇒ ⇒⇒ **包装函数没生成**
/// ⇒ 根因：`JSScopeBuilder.hostWrappers()` 生成的**多行字符串**里，
///   `\(guardClause)` 插进来的一段**带了 `//` 行注释**
///   ⇒ Swift 多行字符串里 `\` 是**续行** ⇒ **`//` 注释把续行后的整行吃掉**
///   ⇒ ⇒⇒ **那个包装函数片段语法坏** ⇒ `evaluateScript` 静默失败 ⇒ 该方法消失 ⭐⭐⭐
///   ⇒ 而它是**逐段 evaluateScript** ⇒ 只有那一个方法没了（其它方法照常）
///
/// ⭐ **这类 bug 极隐蔽**：Swift 侧编译通过、230 个测试全绿 ⇒ **没人验过生成的 JS 语法**
///   ⇒ 所以本门禁就是补这个洞 ⭐⭐⭐
final class HostWrapperJsSyntaxTests: XCTestCase {

    /// ① ⭐⭐⭐ **每一段包装函数都必须自洽**（非空 + 括号平衡 + 以 `catch` 收尾）
    func testEveryWrapperFragmentIsSelfContained() throws {
        let wrappers = JSScopeBuilder.hostWrappers()
        XCTAssertGreaterThan(wrappers.count, 50, "包装函数太少 ⇒ 路径没走到")
        for w in wrappers {
            let trimmed = w.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(trimmed.isEmpty, "有空的包装函数片段")
            // 注释吃掉续行 ⇒ 片段会被截断 ⇒ 括号不平衡
            XCTAssertEqual(trimmed.filter { $0 == "(" }.count,
                           trimmed.filter { $0 == ")" }.count,
                           "包装函数片段括号不平衡（多半是 `//` 注释吃掉了后面的行）⭐⭐⭐：\n\(trimmed)")
            XCTAssertEqual(trimmed.filter { $0 == "{" }.count,
                           trimmed.filter { $0 == "}" }.count,
                           "包装函数片段花括号不平衡（多半是 `//` 注释吃掉了后面的行）⭐⭐⭐：\n\(trimmed)")
            XCTAssertTrue(trimmed.hasSuffix("catch(e) {}"),
                          "包装函数片段没正常收尾（被截断了？）：\n\(trimmed)")
        }
    }

    /// ② ⭐⭐ **不许有「未替换的插值」残留**（`\(obj)` / `\(name)` 出现在生成的 JS 里 = 插值写错了）
    func testNoUnresolvedInterpolationInGeneratedJs() {
        for w in JSScopeBuilder.hostWrappers() {
            XCTAssertFalse(w.contains("\\("),
                           "生成的 JS 里有未替换的插值（`\\(`）⇒ 插值写成了 `\\\\(` ⭐⭐⭐：\n\(w)")
        }
    }

    /// ③ ⭐⭐⭐ **整段拼起来必须语法有效**（用 `node --check`）
    /// ⇒ 跑不动 node ⇒ **显式 SKIP**（不许说成全绿）⭐⭐⭐
    func testGeneratedJsPassesNodeSyntaxCheck() throws {
        let wrappers = JSScopeBuilder.hostWrappers()
        let script = wrappers.joined(separator: "\n")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qr_hostwrappers_check.js")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", "--check", tmp.path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do { try p.run() } catch {
            throw XCTSkip("⚠️【SKIP】本机跑不了 node ⇒ 本次没验「生成的 JS 语法」")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let err = String(data: data, encoding: .utf8) ?? ""
            XCTFail("⭐⭐⭐ **生成的宿主包装函数 JS 语法错** ⇒ `evaluateScript` 静默失败 ⇒ 站方 JS 看到 `java.xxx is undefined` ⇒ 整条规则死定\n\(err)")
            return
        }
    }

    /// ④ ⭐⭐⭐ **不许在多行字符串插值里放 `//` 行注释**（本次事故的直接原因）
    /// ⇒ 判据：生成的每一行里，`//` 之后**不许还有代码**（注释必须整行独占）
    func testNoInlineCommentInGeneratedJs() {
        for w in JSHostBuilderLines(wrappers: JSScopeBuilder.hostWrappers()) {
            // 逐行看：`//` 之后如果还有非空白 ⇒ 说明那行是「代码 + 行注释」
            // ⇒ 在 Swift 多行字符串里会吃掉续行 ⇒ 语法坏 ⭐⭐⭐
            if let idx = w.range(of: "//") {
                let after = w[w.index(after: idx.lowerBound)...]
                if after.contains(where: { !$0.isWhitespace }) {
                    // 允许：字符串字面量里的 `//`（例如 URL 'https://…'）
                    let before = w[..<idx.lowerBound]
                    let quotes = before.filter { $0 == "'" }.count
                    if quotes % 2 == 0 {   // 不在引号里 ⇒ 真注释 ⇒ 后面的代码会被吃掉
                        XCTFail("⭐⭐⭐ 这行是「代码 + `//` 行注释」⇒ 在 Swift 多行字符串里会**吃掉下一行** ⇒ 生成的 JS 语法坏：\n\(w)")
                    }
                }
            }
        }
    }

    private func JSHostBuilderLines(wrappers: [String]) -> [String] {
        wrappers.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
    }
}
