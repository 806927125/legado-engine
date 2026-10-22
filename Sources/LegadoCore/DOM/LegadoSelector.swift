import Foundation

/// **Legado 选择器求值器** —— 把规则链求成节点集。
///
/// 规格：`docs/legado-semantics.md` §S-SEL-01 ~ §S-SEL-06。
/// 参考实现：`reference/js/jsoup-compat.js`（轻阅的 JS DOM，**只读**）。
///
/// ⭐ 三条最关键的语义：
/// 1. **链段里的裸标签名 = 子选择器**（§S-SEL-06）—— 轻阅当属性名 ⇒ 链断 ⇒ 125 源 279 处受害
/// 2. **`text.` = 文本完全相等**（§S-SEL-01）—— 不是「包含」
/// 3. **`class.X Y` = 并列 class**（§S-SEL-02）—— 但**只对带前缀的**；
///    纯 CSS 的 `dl.B dd` 仍是**后代选择器**（零误伤）
public enum LegadoSelector {

    /// 求值结果：节点集 + 取值模式
    public struct Resolved {
        public var nodes: [DOMNode]
        /// 取值模式（`nil` = 取完整文本）
        public var mode: ValueMode?
    }

    // MARK: - 主入口

    /// 在 `root` 内按规则链求值。
    ///
    /// - Parameters:
    ///   - root: 基准节点
    ///   - head: 规则的头段（第一个 `@` 之前）—— 走 **prefixToCss** 语义
    ///   - steps: 链段 —— 走 **KW 分类** 语义
    public static func resolve(root: DOMNode,
                               head: String,
                               headIndex: Int? = nil,
                               steps: [ChainStep]) -> Resolved {
        var nodes: [DOMNode] = []
        var mode: ValueMode?

        // ① 头段（走 prefixToCss 语义；头部排除也在这里生效）
        let (headSpec, headExclusion) = HeadTranslator.translate(head)
        nodes = query(root: root, spec: headSpec)
        // ⭐ 头段索引（`tag.li.0`）：选完之后再取第 N 个
        if let idx = headIndex {
            nodes = idx < 0
                ? (idx + nodes.count >= 0 ? [nodes[idx + nodes.count]] : [])
                : (idx < nodes.count ? [nodes[idx]] : [])
        }
        if !headExclusion.isEmpty {
            nodes = nodes.enumerated()
                .filter { !headExclusion.contains($0.offset) }
                .map { $0.element }
        }

        // ② 链段
        for (i, step) in steps.enumerated() {
            switch step {
            case .sub(let selector, let index, let exclusion):
                guard !nodes.isEmpty else { break }
                var next: [DOMNode] = []
                for n in nodes {
                    let spec = SegmentTranslator.translate(selector)
                    let found = query(root: n, spec: spec)
                    next.append(contentsOf: found)
                }
                // 去重（保序）
                next = dedupe(next)
                // 排除索引（§S-EXCL-01：排除**第 N 个**，0-based）
                if !exclusion.isEmpty {
                    next = next.enumerated()
                        .filter { !exclusion.contains($0.offset) }
                        .map { $0.element }
                }
                // 索引（`tag.li.0` = 第 0 个；`tag.li[-1]` = 最后一个）
                if let idx = index {
                    next = idx < 0
                        ? (idx + next.count >= 0 ? [next[idx + next.count]] : [])
                        : (idx < next.count ? [next[idx]] : [])
                }
                nodes = next
                _ = i

            case .attr(let name):
                // 链尾的属性后缀 ⇒ 取值模式
                mode = ValueMode.fromAttributeName(name)
                // ⚠️ 属性后缀是**终点**：不再往下走链
                //    （不 break 的话 mode 会被后面的 attr 步覆盖 ⇒ 语义错）
                break
            }
        }

        return Resolved(nodes: nodes, mode: mode)
    }

    /// 便捷入口：规则字符串 → 节点集。
    ///
    /// - 规则先过 `RuleParser`（拿到 AST）⇒ 只有 `.chain` 走 DOM 通路
    public static func select(root: DOMNode, rule: String) -> [DOMNode] {
        let ast = RuleParser().parse(rule)
        if case .chain(let head, let headIndex, let steps) = ast {
            return resolve(root: root, head: head, headIndex: headIndex, steps: steps).nodes
        }
        return []
    }

    // MARK: - 查询

    private static func query(root: DOMNode, spec: SelectorSpec) -> [DOMNode] {
        let css = spec.css.trimmingCharacters(in: .whitespaces)
        guard !css.isEmpty else {
            // ⚠️ 空 CSS（纯后置伪类，如 `text.查看目录`）⇒ 候选集 = **root + 所有后代**
            //    （照抄轻阅 `queryOne` 的 `!clean || clean === '*'` 分支）
            //    ⛔ 早先只返回 [root] ⇒ 后置过滤被跳过 ⇒ 命中的是 document 自己
            let candidates = [root] + root.descendants()
            return spec.apply(candidates)
        }
        let found = root.queryAll(css)
        return spec.apply(found)
    }

    private static func dedupe(_ nodes: [DOMNode]) -> [DOMNode] {
        var seen = Set<String>()
        var out: [DOMNode] = []
        for n in nodes {
            if seen.insert(n.domID).inserted { out.append(n) }
        }
        return out
    }
}

/// **取值模式** —— 链尾 `@text` / `@href` / `@html` 之类。
///
/// ⚠️ **已知差异（规格 §S-SEL-04 待定项）**：
/// Legado / Jsoup 的 `@html` = **innerHTML**；
/// 轻阅的 `valueOf` 把 `html` 和 `outerhtml` **都映射成 outerHTML**。
/// ⇒ 两者不一致。本项目按 **Legado 语义**实现（`html` = innerHTML），
/// 对拍时会把这条差异标出来。
public enum ValueMode: Sendable, Equatable {
    /// 完整文本（Jsoup `text()`）
    case text
    /// 自身文本（Jsoup `ownText()`）
    case ownText
    /// 内层 HTML（Jsoup `html()`）
    case html
    /// 外层 HTML（Jsoup `outerHtml()`）
    case outerHTML
    /// 标签名（小写）
    case tag
    /// 整个节点
    case all
    /// 普通属性
    case attribute(String)
    /// URL 属性（`href` / `src` / `action` / `data-src` / `poster`）⇒ **要绝对化**
    case urlAttribute(String)

    /// 从属性后缀名推出取值模式。
    ///
    /// ⚠️ 裸 `text` / `html` / `ownText` 是**取值模式**，不是属性。
    public static func fromAttributeName(_ raw: String) -> ValueMode? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        // `@@text` / `@@html` / `@@ownText` / `@@tag` 别名形式
        if s.hasPrefix("@@") {
            return fromAttributeName(String(s.dropFirst(2)))
        }
        switch s.lowercased() {
        case "text":       return .text
        case "owntext":    return .ownText
        case "html":       return .html
        case "innerhtml":  return .html
        case "outerhtml":  return .outerHTML
        case "tag":        return .tag
        case "all":        return .all
        default: break
        }
        if URLAttributeNames.contains(s.lowercased()) {
            return .urlAttribute(s)
        }
        return .attribute(s)
    }
}

/// 需要绝对化的 URL 属性（轻阅 `valueOf` 的口径）
let URLAttributeNames: Set<String> = ["href", "src", "action", "data-src", "poster"]
