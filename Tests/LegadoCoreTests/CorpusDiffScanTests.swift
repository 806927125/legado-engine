import Foundation
import XCTest
@testable import LegadoCore

/// ⭐⭐⭐⭐⭐ **语料差集扫描**：手写解析器 vs Sextant（栖阅/柴阅同款）
///
/// ⭐ 目的：**让真实语料自己指出缺口**（而不是我猜）
///   ⇒ 对语料里的每一条 JSONPath 规则，比较：
///     · 手写 `JSONPath.parse` 能不能解析
///     · Sextant（SextantFallback.validate）能不能解析
///   ⇒ 差集 = **「Sextant 认得、手写不认」** 的规则 ⇒ 这就是「整条路径作废」的元凶清单 ⭐⭐⭐
///
/// ⚠️ 本测试**只报告不断言**（差集是「事实」不是「对错」）
///   ⇒ 断言由 `SextantParityTests` 钉住「两者必须一致」⇒ 漂移即红 ⭐⭐⭐
///
/// 语料路径：环境变量 `LEGADO_CORPUS`（轻阅仓库的 `sources/*.json`）
final class CorpusDiffScanTests: XCTestCase {

    /// 从语料里抽出「像 JSONPath 的规则串」
    private func corpusPaths() -> [String] {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LEGADO_CORPUS"], FileManager.default.fileExists(atPath: path) else {
            print("⚠️ 未设 LEGADO_CORPUS ⇒ 跳过差集扫描")
            return []
        }
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let arr: [Any]
        if let a = obj as? [Any] { arr = a }
        else if let d = obj as? [String: Any] { arr = [d] }
        else { arr = [] }

        var out: Set<String> = []
        func scan(_ any: Any) {
            if let s = any as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                // ⭐ 只看「像 JSONPath」的：含 `$.` 或 `[?(`，且不是 HTML/正则
                if (t.contains("$.") || t.contains("[?(")) && !t.contains("<") && !t.contains("\n") {
                    out.insert(t)
                }
            } else if let d = any as? [String: Any] {
                for v in d.values { scan(v) }
            } else if let a = any as? [Any] {
                for v in a { scan(v) }
            }
        }
        for src in arr { scan(src) }
        return Array(out).sorted()
    }

    func testCorpusDiffReport() {
        let paths = corpusPaths()
        guard !paths.isEmpty else { return }
        var legacyOnly: [String] = []      // 手写能解析、Sextant 不认
        var sextantOnly: [String] = []     // ⭐ Sextant 能解析、手写不认 ⇒ **缺口**
        for p in paths {
            let legacyOK = JSONPath.parse(p) != nil
            let sextantOK = SextantFallback.validate(p) == nil
            if legacyOK && !sextantOK { legacyOnly.append(p) }
            if !legacyOK && sextantOK { sextantOnly.append(p) }
        }
        print("=== 语料差集扫描 ===")
        print("路径总数：\(paths.count)")
        print("手写能解析 / Sextant 不认：\(legacyOnly.count)")
        for p in legacyOnly.prefix(10) { print("   ⚠️ 手写独有：\(p)") }
        print("⭐ Sextant 能解析 / 手写不认（**缺口**）：\(sextantOnly.count)")
        for p in sextantOnly.prefix(30) { print("   ⭐ 缺口：\(p)") }
    }
}
