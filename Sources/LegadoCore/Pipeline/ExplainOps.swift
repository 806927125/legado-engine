import Foundation

/// ⭐⭐⭐⭐⭐ **诊断 op（`explain` / `explainToc`）** —— 2026-10-25 真机实证
///
/// ⚠️⚠️⚠️ **为什么必须有**：
///   老引擎退役后，App 的「诊断面板」还在调**老引擎**的这两个 op
///   ⇒ **老引擎不能删** ⇒ 新旧两套引擎行为不一致 ⇒ 「很多书源都是这样」的根源之一 ⭐⭐⭐
///   ⇒ 现在：**同样的人话字段**在**新引擎**里实现 ⇒ 老引擎可以彻底删 ⭐⭐⭐
///
/// ⭐ **字段名与老引擎逐字一致**（App 侧按这些 key 拼人话）⇒ 换引擎不用改 App ⭐⭐⭐
public enum ExplainOps {

    /// ⭐⭐⭐ **发现页诊断**（对应老引擎的 `explain` op）
    ///
    /// - Parameters:
    ///   - engine: 引擎（已加载站方 jsLib ⇒ 站方规则能跑）
    ///   - kindUrl: 分类 URL（宿主给的）
    ///   - page: 页码
    public static func explain(engine: SourceEngine, kindUrl: String,
                                page: Int = 1) -> [String: Any] {
        var out: [String: Any] = [:]
        let rules = engine.listRuleForExplore()
        out["请求URL"] = kindUrl
        out["方式"] = "GET"
        out["用的规则"] = (rules?.bookList ?? "") == (engine.source.ruleSearch?.bookList ?? "")
            ? "ruleSearch（ruleExplore.bookList 为空，已回退）" : "ruleExplore"
        out["bookList规则"] = rules?.bookList ?? ""
        if kindUrl.isEmpty {
            out["结论"] = "分类 URL 为空"
            return out
        }
        do {
            let p = try engine.fetchForExplain(kindUrl, page: page)
            out["最终URL"] = p.url
            out["状态码"] = p.statusCode
            out["响应字节"] = p.text.count
            out["页面标题"] = Self.title(of: p.text)
            out["正文开头"] = String(p.text.prefix(200))
            // ⭐ 跑一次列表规则 ⇒ 看命中几个
            let items = (try? engine.listItemsForExplain(rules, page: p)) ?? []
            out["规则命中元素"] = items.count
            if let first = items.first {
                out["书单条目样本"] = String(first.text.prefix(200))
            }
            out["结论"] = items.isEmpty
                ? "规则没命中（站方改版 / URL 不对 / 变量没灌进去）"
                : "命中 \(items.count) 条"
        } catch {
            out["结论"] = "请求失败：\(error)"
            for d in engine.failureDiagnosticLines { out["引擎诊断"] = d; break }
        }
        return out
    }

    /// ⭐⭐⭐ **目录诊断**（对应老引擎的 `explainToc` op）
    public static func explainToc(engine: SourceEngine, tocUrl: String,
                                  bookUrl: String) -> [String: Any] {
        var out: [String: Any] = [:]
        let rules = engine.source.ruleToc
        out["请求URL"] = tocUrl.isEmpty ? bookUrl : tocUrl
        out["chapterList规则"] = rules?.chapterList ?? ""
        out["chapterName规则"] = rules?.chapterName ?? ""
        out["chapterUrl规则"] = rules?.chapterUrl ?? ""
        if out["请求URL"] as? String == "" {
            out["结论"] = "目录 URL 为空"
            return out
        }
        do {
            let p = try engine.fetchForExplain(out["请求URL"] as? String ?? "", page: 1)
            out["最终URL"] = p.url
            out["状态码"] = p.statusCode
            out["响应字节"] = p.text.count
            out["页面标题"] = Self.title(of: p.text)
            let chapters = (try? engine.chaptersForExplain(rules, page: p)) ?? []
            out["规则命中元素"] = chapters.count
            if let first = chapters.first {
                out["取到的章节名"] = first.name
                out["取到的章节URL"] = first.url
            }
            out["结论"] = chapters.isEmpty
                ? "规则没命中（站方改版 / URL 不对 / 变量没灌进去）"
                : "命中 \(chapters.count) 章"
        } catch {
            out["结论"] = "请求失败：\(error)"
            for d in engine.failureDiagnosticLines { out["引擎诊断"] = d; break }
        }
        return out
    }

    /// ⭐ `<title>` 提取
    static func title(of html: String) -> String {
        guard let r = html.range(of: "<title[^>]*>", options: [.regularExpression, .caseInsensitive]),
              let e = html.range(of: "</title>", options: [.regularExpression, .caseInsensitive]),
              r.upperBound <= e.lowerBound else { return "" }
        return String(html[r.upperBound..<e.lowerBound])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
