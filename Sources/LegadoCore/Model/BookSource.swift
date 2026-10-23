import Foundation

/// **书源模型** —— Legado 书源 JSON 的解码。
///
/// ⭐ **容错是硬要求**（轻阅 build215 的教训：`KindsDTO` 少一个 `group` ⇒ 整个 op 结果全废）。
/// ⇒ 缺字段 ⇒ nil；**字段类型不对 ⇒ 当没这个字段**；绝不让整个源解不出来。
///
/// ⚠️ 解码**只做「结构」**，不做「语义」——
/// 规则串里到底是什么语法，交给 `RuleParser` 判定，不要在模型层猜。
public struct BookSource: Codable, Sendable {
    public var bookSourceName: String
    public var bookSourceUrl: String
    public var bookSourceGroup: String?
    public var bookSourceComment: String?
    public var enabled: Bool?
    public var enabledExplore: Bool?
    /// 源级请求头（Legado 里是 **JSON 字符串**）
    public var header: String?
    /// 发现页入口（老式「标题::URL」多行，或新版 JSON 数组）
    public var exploreUrl: String?
    /// 搜索入口（URL 规则）
    public var searchUrl: String?

    public var ruleSearch: RuleFields?
    public var ruleExplore: RuleFields?
    public var ruleBookInfo: RuleFields?
    public var ruleToc: RuleFields?
    public var ruleContent: RuleFields?
    /// ⭐⭐ **登录脚本**（`loginUrl`）—— 一段 JS，**加载到全局**（定义 `function login()` 等）
    public var loginUrl: String?
    /// ⭐ **登录界面定义**（`loginUi`）—— JSON 数组 **或** `@js:` 脚本
    public var loginUi: String?
    /// ⭐ **登录态检测脚本**（`loginCheckJs`）—— 对当前页跑
    public var loginCheckJs: String?
    /// ⭐ **登录信息**（`loginInfo`）—— key → value 的 map（站方 `source.getLoginInfoMap()` 读它）
    public var loginInfo: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case bookSourceName, bookSourceUrl, bookSourceGroup, bookSourceComment
        case enabled, enabledExplore, header, exploreUrl, searchUrl
        case ruleSearch, ruleExplore, ruleBookInfo, ruleToc, ruleContent
        case loginUrl, loginUi, loginCheckJs, loginInfo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookSourceName = (try? c.decode(String.self, forKey: .bookSourceName)) ?? ""
        bookSourceUrl = (try? c.decode(String.self, forKey: .bookSourceUrl)) ?? ""
        bookSourceGroup = try? c.decode(String.self, forKey: .bookSourceGroup)
        bookSourceComment = try? c.decode(String.self, forKey: .bookSourceComment)
        enabled = (try? c.decode(Bool.self, forKey: .enabled))
            ?? ((try? c.decode(String.self, forKey: .enabled)) == "true")
        enabledExplore = (try? c.decode(Bool.self, forKey: .enabledExplore))
            ?? ((try? c.decode(String.self, forKey: .enabledExplore)) == "true")
        header = try? c.decode(String.self, forKey: .header)
        exploreUrl = try? c.decode(String.self, forKey: .exploreUrl)
        searchUrl = try? c.decode(String.self, forKey: .searchUrl)
        ruleSearch = try? c.decode(RuleFields.self, forKey: .ruleSearch)
        ruleExplore = try? c.decode(RuleFields.self, forKey: .ruleExplore)
        ruleBookInfo = try? c.decode(RuleFields.self, forKey: .ruleBookInfo)
        ruleToc = try? c.decode(RuleFields.self, forKey: .ruleToc)
        ruleContent = try? c.decode(RuleFields.self, forKey: .ruleContent)
        loginUrl = try? c.decode(String.self, forKey: .loginUrl)
        loginUi = try? c.decode(String.self, forKey: .loginUi)
        loginCheckJs = try? c.decode(String.self, forKey: .loginCheckJs)
        loginInfo = try? c.decode([String: String].self, forKey: .loginInfo)
    }

    public init(bookSourceName: String, bookSourceUrl: String) {
        self.bookSourceName = bookSourceName
        self.bookSourceUrl = bookSourceUrl
    }
}

/// **规则字段集** —— `ruleSearch` / `ruleExplore` / `ruleBookInfo` / `ruleToc` / `ruleContent` 共用。
///
/// ⭐ **为什么共用一个结构**（而不是五个）：
/// Legado 的五个规则块字段**大量重名**（`name` / `author` / `bookUrl` / `intro` / `coverUrl` …），
/// 而各块独有字段很少（`bookList` / `chapterList` / `content` …）。
/// ⇒ 共用一个结构 ⇒ 缺失字段自然为 nil ⇒ **容错成本为零**，也不会漏字段。
/// ⇒ 拼错的字段会被 Codable 忽略（不报错），这正是我们要的容错。
public struct RuleFields: Codable, Sendable {
    // 通用
    public var name: String?
    public var author: String?
    public var kind: String?
    public var intro: String?
    public var coverUrl: String?
    public var lastChapter: String?
    public var bookUrl: String?
    public var wordCount: String?

    public var searchUrl: String?
    /// ⭐⭐ **`ruleExplore.exploreUrl`** —— 站方会把发现页 URL 写在**规则块里**（不是顶层）
    ///
    /// ⚠️ **老引擎的兜底**：`ruleText(src.exploreUrl) || ruleText(src.ruleExplore && src.ruleExplore.exploreUrl)`
    /// ⇒ 顶层空 ⇒ **试规则块里的** ⇒ 少了这条 ⇒ 一批源直接「该书源没有发现规则」⭐
    public var exploreUrl: String?
    // 列表
    public var bookList: String?
    // 详情
    public var tocUrl: String?
    // 目录
    public var chapterList: String?
    public var chapterName: String?
    public var chapterUrl: String?
    /// ⭐ **卷标题判定规则**（站方写法：`.catalog-section-title@text||span@text`）
    /// ⇒ 非空 ⇒ 这一项是卷标题（不是章节）
    public var isVolume: String?
    public var isVip: String?
    public var nextTocUrl: String?
    /// ⭐ **列表页翻页**（`ruleSearch.nextUrl` / `ruleExplore.nextUrl`）
    public var nextUrl: String?
    // 正文
    public var content: String?
    public var nextContentUrl: String?
    public var replaceRegex: String?
    public var sourceRegex: String?

    /// ⭐⭐⭐ **`ruleBookInfo.init`** —— 在**详情页结果**上跑一次，
    /// **把输出当成后面所有字段规则的基准**。
    ///
    /// ⚠️ **JSON 接口源几乎全靠它**（`init: "$.data"` 把 `{code,msg,data:{…}}` 缩成 `{…}`）。
    ///
    /// ⚠️ **属性不能叫 `init`**（Swift 保留字）⇒ 属性叫 `initRule`，对外 JSON 键仍是 `init`。
    public var initRule: String?

    private enum CodingKeys: String, CodingKey {
        case name, author, kind, intro, coverUrl, lastChapter, bookUrl, wordCount
        case searchUrl, exploreUrl, bookList, tocUrl
        case chapterList, chapterName, chapterUrl, isVolume, isVip, nextTocUrl, nextUrl
        case content, nextContentUrl, replaceRegex, sourceRegex
        case initRule = "init"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ⭐⭐ **规则字段的容错解码** —— 站方一个字段可能是：
        //   ① 字符串（最常见）② **字符串数组**（多条候选规则）③ null
        //   ⇒ 数组要**合并成换行分隔**（站方的多规则写法是换行 ⇒ 列表出口合并 / 字段出口取第一个非空）
        //   ⇒ 以前只解 String ⇒ 数组形式**整条规则丢失**（静默）⭐
        func r(_ k: CodingKeys) -> String? {
            if let s = try? c.decode(String.self, forKey: k) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            if let a = try? c.decode([String].self, forKey: k) {
                let lines = a
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
            return nil
        }
        name = r(.name)
        author = r(.author)
        kind = r(.kind)
        intro = r(.intro)
        coverUrl = r(.coverUrl)
        lastChapter = r(.lastChapter)
        bookUrl = r(.bookUrl)
        wordCount = r(.wordCount)
        searchUrl = r(.searchUrl)
        exploreUrl = r(.exploreUrl)
        bookList = r(.bookList)
        tocUrl = r(.tocUrl)
        chapterList = r(.chapterList)
        chapterName = r(.chapterName)
        chapterUrl = r(.chapterUrl)
        isVolume = r(.isVolume)
        isVip = r(.isVip)
        nextTocUrl = r(.nextTocUrl)
        nextUrl = r(.nextUrl)
        content = r(.content)
        nextContentUrl = r(.nextContentUrl)
        replaceRegex = r(.replaceRegex)
        sourceRegex = r(.sourceRegex)
        initRule = r(.initRule)
    }

    public init() {}
}
