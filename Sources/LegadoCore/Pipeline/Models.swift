import Foundation

/// **分类** —— 发现页的一个入口。
public struct SourceCategory: Sendable, Equatable {
    public var title: String
    public var url: String
    /// Legado 的 `style`（网格/列表），本引擎暂不使用
    public var style: String?

    public init(title: String, url: String, style: String? = nil) {
        self.title = title; self.url = url; self.style = style
    }
}

/// **书** —— 列表页的一项。
public struct Book: Sendable, Equatable {
    public var name: String
    public var author: String
    /// **绝对地址**（相对地址已相对「列表页 URL」绝对化）
    public var bookUrl: String
    public var coverUrl: String
    public var intro: String
    public var kind: String
    public var lastChapter: String
    /// ⭐ **字数**（`rule*.wordCount`）—— 125 源里 **111 处**在用
    public var wordCount: String
    /// 附加字段（给后续阶段用）
    public var raw: [String: String]

    public init(name: String = "", author: String = "", bookUrl: String = "",
                coverUrl: String = "", intro: String = "", kind: String = "",
                lastChapter: String = "", wordCount: String = "",
                raw: [String: String] = [:]) {
        self.name = name; self.author = author; self.bookUrl = bookUrl
        self.coverUrl = coverUrl; self.intro = intro; self.kind = kind
        self.lastChapter = lastChapter; self.wordCount = wordCount; self.raw = raw
    }
}

/// **书籍详情** —— 详情页跑完的结果。
public struct BookInfo: Sendable, Equatable {
    public var name: String
    public var author: String
    public var intro: String
    public var kind: String
    public var coverUrl: String
    public var lastChapter: String
    /// ⭐ **字数**（`ruleBookInfo.wordCount`）—— 44 个源在用
    public var wordCount: String
    public var bookUrl: String
    /// 目录页 URL（**空** ⇒ 目录规则在详情页上跑）
    public var tocUrl: String
    /// 所属书源名
    public var sourceName: String
    public var raw: [String: String]

    public init(name: String = "", author: String = "", intro: String = "", kind: String = "",
                coverUrl: String = "", lastChapter: String = "", wordCount: String = "",
                bookUrl: String = "", tocUrl: String = "", sourceName: String = "",
                raw: [String: String] = [:]) {
        self.name = name; self.author = author; self.intro = intro; self.kind = kind
        self.coverUrl = coverUrl; self.lastChapter = lastChapter
        self.wordCount = wordCount; self.bookUrl = bookUrl
        self.tocUrl = tocUrl; self.sourceName = sourceName; self.raw = raw
    }
}

/// **章节** —— 目录里的一项。
public struct Chapter: Sendable, Equatable {
    public var name: String
    /// 章节页 URL（**空** ⇒ 这是「卷标题」）
    public var url: String
    /// **是不是卷标题**（没有章节 URL ⇒ 是）
    public var isVolume: Bool
    /// ⭐ **是不是付费章节**（`ruleToc.isVip`）—— 9 个源在用
    public var isVip: Bool
    /// 目录里的序号
    public var index: Int

    public init(name: String = "", url: String = "", isVolume: Bool = false,
                isVip: Bool = false, index: Int = 0) {
        self.name = name; self.url = url; self.isVolume = isVolume
        self.isVip = isVip; self.index = index
    }
}

/// **一页** —— 抓回来的响应 + 解析好的 DOM。
public struct Page {
    /// **最终 URL**（重定向后）—— 相对地址绝对化的基准
    public var url: String
    /// 正文
    public var text: String
    /// 解析好的 DOM（HTML 响应才有）
    public var document: DOMNode?
    /// 响应是不是 JSON
    public var isJSON: Bool

    public init(url: String, text: String, document: DOMNode?, isJSON: Bool) {
        self.url = url; self.text = text; self.document = document; self.isJSON = isJSON
    }
}

/// ⭐ **登录界面里的一个元素**（站方 `loginUi` 的一条）
///
/// **站方真实形态**（125 源实测：猫眼看书 / 番茄小说TS）：
/// ```json
/// [ { "name": "🐈猫眼①", "type": "button", "action": "Source('first')" },
///   { "name": "服务器", "type": "text", "viewName": "host" } ]
/// ```
public struct LoginField: Sendable, Equatable {
    /// 显示名（站方写得很花哨 ⇒ 原样保留）
    public var name: String
    /// 元素类型：`text`（输入框）/ `button`（按钮）/ `check`（勾选）
    public var type: String
    /// 输入框的提示
    public var hint: String?
    /// ⭐ **按钮的动作**（站方 JS 表达式，由引擎在 JS 环境里求值）
    public var action: String?
    /// ⭐ **输入框的键**（站方用它读 `source.getLoginInfoMap()`）
    public var viewName: String?
    /// 输入框的默认值
    public var defaultValue: String?

    public init(name: String = "", type: String = "text", hint: String? = nil,
                action: String? = nil, viewName: String? = nil, defaultValue: String? = nil) {
        self.name = name
        self.type = type
        self.hint = hint
        self.action = action
        self.viewName = viewName
        self.defaultValue = defaultValue
    }
}
