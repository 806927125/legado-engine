import Foundation

/// **头段翻译器** —— `prefixToCss` 语义。
///
/// ⚠️ **头段和链段的规则不一样，这是最容易搞错的地方**：
///
/// | | 头段（第一个 `@` 之前） | 链段（`@` 后面） |
/// |---|---|---|
/// | 翻译规则 | `prefixToCss` | KW 分类（sub / attr） |
/// | `dl.B dd` | **原样**（标准 CSS 后代） | —— |
/// | `class.book` | `.book` | `.book`（子选择器） |
/// | `class.a b` | `.a.b`（并列 class） | —— |
/// | `text.x` | `:textEquals(x)` | `:textEquals(x)` |
///
/// 轻阅的 `parseChain`：**头段走 `prefixToCss`，链段走 KW 分类**。
/// ⇒ 我早先把两者混成一个分类器 ⇒ 纯 CSS 的 `dl.B dd` 会被误判成属性名（**已修**）。
///
/// ⭐ 照抄轻阅 `prefixToCss` 的三条要点：
/// 1. 标记正则 `([a-zA-Z_][\w-]*)\.` —— **贪婪、无词边界**
/// 2. 关键字命中 ⇒ 按 KW 翻译；**真实 HTML 标签名命中 ⇒ 当「标签 + 类名」**（值可带空格）
///    ⇒ 这就是 `dl.B dd` 的后代语义能保住的原因
/// 3. 标记的值边界 = **下一个标记的起点**（或结尾），不是下一个词
public enum HeadTranslator {

    /// 会被识别成「Legado 前缀」的关键字
    static let keywords: Set<String> = ["class", "id", "tag", "text", "owntext", "children"]

    /// 把头段翻译成 CSS + 后置伪类 + 头部排除索引。
    public static func translate(_ raw: String) -> (spec: SelectorSpec, exclusion: [Int]) {
        var h = (raw ?? "").trimmingCharacters(in: .whitespaces)

        // ① 剥掉头部排除后缀 `!N`（§S-EXCL-01：排除**第 N 个**，0-based）
        var exclusion: [Int] = []
        if let bang = h.lastIndex(of: "!") {
            let tail = String(h[h.index(after: bang)...])
            let ids = tail.components(separatedBy: ":").compactMap { Int($0) }
            if !ids.isEmpty {
                exclusion = ids
                h = String(h[..<bang]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !h.isEmpty else { return (SelectorSpec(css: ""), exclusion) }

        // ② 扫标记：正则 `([a-zA-Z_][\w-]*)\.`，贪婪、无词边界
        let marks = scanMarks(h)
        guard !marks.isEmpty else {
            // ⭐ 无前缀 ⇒ **原样当纯 CSS**（`dl.B dd` 的后代语义要保住）
            return (SelectorSpec(css: h), exclusion)
        }

        // ③ 逐标记替换：值 = 从本标记值起点到**下一个标记起点**（或结尾）
        var out = ""
        var filters: [PseudoFilter] = []
        let chars = Array(h)
        var cursor = 0

        for (idx, m) in marks.enumerated() {
            let valueEnd = (idx + 1 < marks.count) ? marks[idx + 1].start : chars.count
            let value = String(chars[m.valueStart..<valueEnd]).trimmingCharacters(in: .whitespaces)

            out += String(chars[cursor..<m.start])
            switch m.kind {
            case .keyword(let kw):
                switch kw {
                case "class":
                    // ⭐ class 的值可以带空格 ⇒ 空格是**并列 class**
                    //    （125 源 40 处；站方要写后代用 `class.a@tag.b`）
                    let parts = value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                        .map(String.init).filter { !$0.isEmpty }
                    out += parts.map { "." + $0 }.joined()
                case "id":
                    out += "#" + value
                case "tag":
                    out += value
                case "text":
                    // ⭐ 文本**完全相等**（不是包含）—— 轻阅 build214 修的
                    filters.append(.textEquals(value))
                case "owntext":
                    filters.append(.containsOwn(value))
                case "children":
                    out += "*"
                default:
                    out += value
                }
            case .implicitTag(let raw):
                // 真实标签当前缀时，值整体当**类名**（可带空格）
                // ⇒ `dl.B dd` ⇒ "dl" + "." + "B dd" = "dl.B dd" ⇒ 后代语义保住 ✅
                out += value.isEmpty ? raw : raw + "." + value
            }
            cursor = valueEnd
        }
        out += String(chars[cursor...])

        return (SelectorSpec(css: out.trimmingCharacters(in: .whitespaces), filters: filters), exclusion)
    }

    // MARK: - 标记扫描

    enum MarkKind {
        case keyword(String)
        case implicitTag(String)
    }

    struct Mark {
        let kind: MarkKind
        let start: Int
        let valueStart: Int
    }

    /// 扫描 `([a-zA-Z_][\w-]*)\.` 形式的标记。
    ///
    /// ⚠️ **必须无词边界**（照抄轻阅）—— `class.clearfix.chapter-list` 里
    /// 「clearfix.」也会被扫到，只是不在 KW 里、也不是标签名 ⇒ 不 push。
    private static func scanMarks(_ h: String) -> [Mark] {
        let chars = Array(h)
        var marks: [Mark] = []
        var i = 0
        while i < chars.count {
            // 匹配 `[a-zA-Z_][\w-]*` 后跟一个 '.'
            guard isWordStart(chars[i]) else { i += 1; continue }
            var j = i + 1
            while j < chars.count, isWordChar(chars[j]) { j += 1 }
            guard j < chars.count, chars[j] == "." else { i = j; continue }

            let name = String(chars[i..<j]).lowercased()
            let valueStart = j + 1
            if keywords.contains(name) {
                marks.append(Mark(kind: .keyword(name), start: i, valueStart: valueStart))
            } else if HTMLTagNames.contains(name) {
                marks.append(Mark(kind: .implicitTag(name), start: i, valueStart: valueStart))
            }
            // ⚠️ 绝不把游标退回 i+1（轻阅注释里专门警告过）：
            //    否则 `class.` 里的 "s." 会被当成新前缀，切出一堆垃圾标记
            i = valueStart
            if marks.count > 8 { break }   // 防御畸形规则
        }
        return marks
    }

    private static func isWordStart(_ c: Character) -> Bool {
        c.isLetter || c == "_"
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }
}

/// **链段翻译器** —— KW 分类语义。
///
/// 链段形如 `tag.li` / `class.book` / `id.x` / `text.y` / `li`（裸标签名）/ `text`（属性后缀）。
public enum SegmentTranslator {

    /// 把链段的 selector（`"tag:li"` / `"class:x y"` / `"id:x"`）翻成 CSS + 后置过滤
    public static func translate(_ raw: String) -> SelectorSpec {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let sep = s.firstIndex(of: ":") else {
            // 没有类型前缀 ⇒ 纯 CSS
            return SelectorSpec(css: s)
        }
        let kind = String(s[s.startIndex..<sep])
        let value = String(s[s.index(after: sep)...]).trimmingCharacters(in: .whitespaces)

        switch kind {
        case "class":
            let parts = value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                .map(String.init).filter { !$0.isEmpty }
            return SelectorSpec(css: parts.map { "." + $0 }.joined())
        case "id":
            return SelectorSpec(css: "#" + value)
        case "tag":
            return SelectorSpec(css: value)
        case "text":
            return SelectorSpec(css: "", filters: [.textEquals(value)])
        case "owntext":
            return SelectorSpec(css: "", filters: [.containsOwn(value)])
        default:
            return SelectorSpec(css: s)
        }
    }
}
