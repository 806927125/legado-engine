import Foundation

/// **规则求值的基准（base）** —— `result` 语义的唯一决定者。
///
/// 规格：`docs/legado-semantics.md` §S-RES ⭐⭐⭐（整份规格里最要紧的一条）。
///
/// ⭐ **轻阅两次栽在这里**：
/// - build206：把 `result` 一律换成「当前页原文」⇒ 条目级规则 `result.book_id` 恒 undefined
///   ⇒ 站方生成的载荷只剩 `{"tab":"小说","url":""}` ⇒ 服务器回「illegal base64」
/// - build213：改成按基准分流 ⇒ 修好
///
/// ⇒ **在自研引擎里，基准是类型，不是注释。** 谁调用求值器，谁就得说清基准是什么，
/// 编译器会逼他。
public enum RuleBase: Sendable {
    /// **页面级**：当前页的**原始内容**（HTML 源码，不是 `textContent` 纯文本）
    case page(String)
    /// **条目级**：列表里的一项（DOM 节点）
    case element(DOMNodeRef)
    /// **init 输出级 / JSON 对象级**：一个结构化对象
    case json(JSONValue)
    /// **元素级**：DOM 节点（与 `.element` 区分：后者是列表项）
    case node(DOMNodeRef)

    /// `result` 的值 —— **由基准决定，不由调用方决定**。
    public var resultValue: RuleValue {
        switch self {
        case .page(let raw):
            // ⚠️ 必须是**页原文**（站方 @js: 里常写 `String(result).match(/<div class="book-like">…/)`）
            return .string(raw)
        case .element(let n), .node(let n):
            return .node(n)
        case .json(let j):
            return .json(j)
        }
    }
}

/// 求值上下文 —— 一次求值所需要的全部外部事实。
///
/// ⚠️ **只传得进来的东西**：`book` / `source` 这些宿主对象**必须真的传进来**。
/// 轻阅 build161 的教训：站方 `ruleToc.chapterList` 第一句就 `book.getVariable('custom')`
/// ⇒ 不给 book 就抛 `Cannot read properties of undefined` ⇒ **整条规则静默失效**。
public struct EvalContext: @unchecked Sendable {
    /// 当前基准
    public var base: RuleBase
    /// 当前页 URL（**不是**书源首页）—— 站方靠 `baseUrl.indexOf("aaccoo.com")` 判断平台
    public var baseUrl: String
    /// 当前页原文（页面级规则的 `result` 与 `raw` 都取它）
    public var raw: String
    /// 书籍对象（站方 JS 里 `book.getVariable(...)` 的载体）
    public var book: HostObject?
    /// 书源对象（站方 JS 里 `source.getVariable(...)` 的载体）
    public var source: HostObject?
    /// 章节对象
    public var chapter: HostObject?
    /// 源级变量（`@put` / `@get` 存的东西）
    public var vars: [String: String]
    /// 页码
    public var page: Int
    /// 搜索词
    public var key: String
    /// 响应体是不是 JSON —— 会影响模式判定（§S-CLS-08）
    public var isJSON: Bool
    /// 当前页的 DOM（页面级基准）—— 选择器规则要靠它
    ///
    /// ⚠️ 为什么要单独放 ctx 而不是 base：
    /// `base` 的**文本**是页原文（`.page(raw)`），
    /// 但**选择器**需要一个已解析的 DOM ⇒ 两者分开，DOM 由宿主注入。
    public var document: DOMNode?

    public init(base: RuleBase,
                baseUrl: String = "",
                raw: String = "",
                book: HostObject? = nil,
                source: HostObject? = nil,
                chapter: HostObject? = nil,
                vars: [String: String] = [:],
                page: Int = 1,
                key: String = "",
                isJSON: Bool = false,
                document: DOMNode? = nil) {
        self.base = base
        self.baseUrl = baseUrl
        self.raw = raw
        self.book = book
        self.source = source
        self.chapter = chapter
        self.vars = vars
        self.page = page
        self.key = key
        self.isJSON = isJSON
        self.document = document
    }
}

/// 宿主对象（`book` / `source` / `chapter`）—— 核心层不关心它们的实现，
/// 只要求：**必须是「包过 API 的对象」**，不是裸字典。
///
/// 规格 §S-SCP-03 / §S-SCP-04。
public struct HostObject: Sendable {
    public let name: String
    /// 方法表：站方 JS 调 `book.getVariable('x')` ⇒ 落到这里
    public let methods: [String: HostMethod]

    public init(name: String, methods: [String: HostMethod] = [:]) {
        self.name = name
        self.methods = methods
    }

    public func call(_ method: String, _ args: [String]) -> String? {
        methods[method]?(args)
    }
}

public typealias HostMethod = @Sendable ([String]) -> String?
