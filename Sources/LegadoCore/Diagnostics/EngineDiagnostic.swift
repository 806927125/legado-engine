import Foundation

/// 引擎诊断 —— **横切的一等公民**。
///
/// 规格：`docs/legado-semantics.md` §S-DIA（6 条）。
///
/// ⭐ **轻阅最贵的一课：诊断误导比没有诊断更贵。**
/// - 诊断只走 HTML/CSS 路径 ⇒ 对 JSON 源和复合规则**必然**报「命中 0 个」
///   ⇒ 结论恒为「结构跟规则对不上」⇒ **所有人都以为规则写错了，其实规则是对的**
/// - 诊断的 ctx 不带 `book` ⇒ 站方 JS 第一句就抛 ⇒ 永远 0 命中
/// - 诊断真去 fetch `data:` 伪 URL ⇒ 状态码 0 / 响应 21 字节 ⇒ **全是废数据**
///
/// ⇒ 所以诊断**必须走真实路径**，而且**必须能说清「我测的是什么」**。
public struct EngineDiagnostic: Sendable {
    /// 规则原文
    public let rule: String
    /// 解析出的模式
    public let mode: String?
    /// 走了哪个分支（页面级 / 条目级 / JSONPath / 选择器 / JS …）
    public let branch: String?
    /// 每一步的中间值（出问题时**不用猜**）
    public var steps: [Step] = []
    /// 失败原因 —— **必须有**，不许静默返回空
    public var failure: Failure?
    /// 这次诊断**测的到底是什么**（防止「测 A 说 B 的问题」）
    public var scope: String = ""

    public struct Step: Sendable {
        public let name: String
        public let detail: String
        public init(name: String, detail: String) {
            self.name = name
            self.detail = detail
        }
    }

    public enum Failure: Sendable, Equatable {
        /// 规则语法不认识（**不是**空结果）
        case unsupportedSyntax(String)
        /// 规则认识，但没命中
        case noMatch(reason: String)
        /// 宿主对象没传（book/source 缺失）
        case missingHostObject(String)
        /// JS 执行失败
        case jsError(String)
        /// 网络失败
        case network(String)
        /// 其它
        case other(String)
    }

    public init(rule: String, mode: String? = nil, branch: String? = nil) {
        self.rule = rule
        self.mode = mode
        self.branch = branch
    }

    public var summary: String {
        var parts: [String] = []
        if let mode { parts.append("模式=\(mode)") }
        if let branch { parts.append("分支=\(branch)") }
        if let f = failure { parts.append("失败=\(f)") }
        return parts.isEmpty ? "（无附加信息）" : parts.joined(separator: " · ")
    }
}

/// 诊断的**结论分级** —— 供 UI 区分「服务器没数据」和「规则没命中」。
///
/// ⭐ 轻阅 build194 的教训：聚合源对没抓到章节的书会返回**一条占位**
/// （`title == 书名`）⇒ 以前当成了「1 个章节」⇒ 用户看到「目录只有 1 章」。
/// ⇒ UI 必须能区分三态：
/// ① 服务器只回卷信息、没章节 ② 服务器连 data 都是空 ③ 真·规则没命中
public enum DiagnosisConclusion: String, Sendable {
    /// 规则没命中
    case ruleNotMatched = "rule-not-matched"
    /// 响应本身就没有数据（服务器侧）
    case serverEmpty = "server-empty"
    /// 只返回了占位信息
    case placeholderOnly = "placeholder-only"
    /// 宿主侧没传必需对象
    case hostMissing = "host-missing"
    /// 规则不支持
    case unsupported = "unsupported"
    /// 一切正常
    case ok = "ok"
}
