#!/usr/bin/env python3
"""把 `Sources/LegadoCore/JS/org-jsoup.js` 嵌进 `OrgJsoupCompat.swift`。

**为什么要这一步**：引擎的 JS 兼容层是「**源码编进 Swift**」（不依赖 `Bundle.module`
⇒ iOS App / conformance 可执行文件 / Linux 沙盒三处都一致）。

⚠️ **单一真相**：`org-jsoup.js` 是**源**，`OrgJsoupCompat.swift` 是**产物**。
⇒ 门禁 `OrgJsoupCompatTests` 会**重新生成一遍并逐字比对** ⇒ 产物过期 ⇒ 门禁红 ⭐

用法：`python3 Scripts/embed_js.py`
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Resources/org-jsoup.js"
DST = ROOT / "Sources/LegadoCore/JS/OrgJsoupCompat.swift"

HEADER = '''import Foundation

/// ⭐⭐⭐⭐⭐ **`org.jsoup` 兼容层**（纯 JS · 无依赖 · JSC / Node 共用同一份）
///
/// ⚠️⚠️ **本文件是【产物】** —— 源是 `Resources/org-jsoup.js`
/// ⇒ 改 JS 请改**那个文件**，然后跑 `python3 Scripts/embed_js.py` 重新生成
/// ⇒ 门禁 `OrgJsoupCompatTests` 会**逐字比对** ⇒ 产物过期就红 ⭐⭐⭐
///
/// ──────────────────────────────────────────────────────────────
/// **为什么要「纯 JS」而不是「Swift 解析 + 桥回 JS」**（2026-10-26 实证）
/// ──────────────────────────────────────────────────────────────
///   · **JSC（真机）没有 DOM**；**Node（沙盒）也没有 DOM**
///   · 而 **Node 后端不回调 Swift**（`__hostJSON` 是纯 JS 实现 + 预置缓存）
///   ⇒ ⇒ 任何能力只要「**沙盒能验**」⇒ 就必须写在 **JS** 里
///   ⇒ ⇒ **一份 JS ⇒ 两端一模一样** ⇒ 沙盒绿 = 真机绿（不是「沙盒绿、真机错」）⭐⭐⭐
///
/// ──────────────────────────────────────────────────────────────
/// **语义照抄老引擎**（轻阅 `reference/js/org-jsoup.js`）—— 老实现是事实标准
/// ──────────────────────────────────────────────────────────────
///   · 老实现建在 **WKWebView 的 DOM** 上 ⇒ 这里改成「**自带的迷你 DOM**」
///   · 对外 API 面保持一致：`Jsoup.parse` / `Document.select` / `Document.body`
///     / `Element.text|ownText|html|outerHtml|attr|remove|select|children|parent`
///     / `Elements`（**真数组** + `size/first/last/each/attr/text/html/select`…）
///   · `Elements` 必须是**真数组** ⇒ 站方的 `Array.from(els).reverse()` 才能用 ⭐⭐⭐
///
/// ⭐ **站方真实用量**（125 源语料，剥注释后统计）：
///   · `org.jsoup.Jsoup.parse` **43 处 / 7 个源**
///   · 选择器：`a` / `li` / `.articleHide` / `.muludiv` / `ul.stui-content__playlist`
///     / `li a` / `ul.nav.nav-pills li a` / `.noveldefaultimage` / `p.xs-show`
///     / `ul.topul > li` / `#jieqi_page_contents .c_row` / `#jieqi_page_contents tr`
///     / `:matchesOwn(内容未加载完成|关闭(阅读|小说)模式)`（**jsoup 专有** ⇒ 已支持）
///   · 方法：`text` 62 / `size` 43 / `attr` 21 / `first` 12 / `body` 10 / `remove` 9
///     / `html` 2 / `toString` 1 / `outerHtml` 1
public enum OrgJsoupCompat {
    /// ⭐ **JS 源码本体**（`#` 包裹的 raw string ⇒ 反斜杠不被当转义）
    public static let source: String = ##"""
'''

FOOTER = '''
"""##
}
'''


def main() -> int:
    js = SRC.read_text(encoding="utf-8")
    # raw string（##"""…"""#）里不能出现 `"""`；也不能有 `\#(`（会被当插值）
    if '"""' in js:
        print("❌ JS 里出现了 `\"\"\"` ⇒ 不能放进 raw string", file=sys.stderr)
        return 1
    if "\\#(" in js:
        print("❌ JS 里出现了 `\\#(` ⇒ 会被当插值", file=sys.stderr)
        return 1
    for i, line in enumerate(js.split("\n"), 1):
        if line.endswith("\\"):
            print(f"❌ 第 {i} 行以反斜杠结尾 ⇒ raw string 里会续行", file=sys.stderr)
            return 1
    DST.write_text(HEADER + js + FOOTER, encoding="utf-8")
    print(f"✅ 已生成 {DST.relative_to(ROOT)}（{len(js)} 字节 JS）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
