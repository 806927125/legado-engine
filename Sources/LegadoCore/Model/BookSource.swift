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

    private enum CodingKeys: String, CodingKey {
        case bookSourceName, bookSourceUrl, bookSourceGroup, bookSourceComment
        case enabled, enabledExplore, header, exploreUrl, searchUrl
        case ruleSearch, ruleExplore, ruleBookInfo, ruleToc, ruleContent
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
    // 正文
    public var content: String?
    public var nextContentUrl: String?
    public var replaceRegex: String?
    public var sourceRegex: String?

    private enum CodingKeys: String, CodingKey {
        case name, author, kind, intro, coverUrl, lastChapter, bookUrl, wordCount
        case searchUrl, bookList, tocUrl
        case chapterList, chapterName, chapterUrl, isVolume, isVip, nextTocUrl
        case content, nextContentUrl, replaceRegex, sourceRegex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try? c.decode(String.self, forKey: .name)
        author = try? c.decode(String.self, forKey: .author)
        kind = try? c.decode(String.self, forKey: .kind)
        intro = try? c.decode(String.self, forKey: .intro)
        coverUrl = try? c.decode(String.self, forKey: .coverUrl)
        lastChapter = try? c.decode(String.self, forKey: .lastChapter)
        bookUrl = try? c.decode(String.self, forKey: .bookUrl)
        wordCount = try? c.decode(String.self, forKey: .wordCount)
        searchUrl = try? c.decode(String.self, forKey: .searchUrl)
        bookList = try? c.decode(String.self, forKey: .bookList)
        tocUrl = try? c.decode(String.self, forKey: .tocUrl)
        chapterList = try? c.decode(String.self, forKey: .chapterList)
        chapterName = try? c.decode(String.self, forKey: .chapterName)
        chapterUrl = try? c.decode(String.self, forKey: .chapterUrl)
        isVolume = try? c.decode(String.self, forKey: .isVolume)
        isVip = try? c.decode(String.self, forKey: .isVip)
        nextTocUrl = try? c.decode(String.self, forKey: .nextTocUrl)
        content = try? c.decode(String.self, forKey: .content)
        nextContentUrl = try? c.decode(String.self, forKey: .nextContentUrl)
        replaceRegex = try? c.decode(String.self, forKey: .replaceRegex)
        sourceRegex = try? c.decode(String.self, forKey: .sourceRegex)
    }

    public init() {}
}
