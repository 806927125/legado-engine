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
    public var mode: String?
    /// 走了哪个分支（页面级 / 条目级 / JSONPath / 选择器 / JS …）
    public var branch: String?
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
        /// 基准类型不对（例：响应是 HTML，规则却是 JSONPath）
        case baseTypeMismatch(expected: String, actual: String)
        /// JS 执行失败
        case jsError(String)
        /// 网络失败
        case network(String)
        /// 其它
        case other(String)

        /// ⭐ **「这是不是真错误」** —— 真错误 ⇒ 宿主该报错；没匹配 ⇒ 正常结果。
        ///
        /// ⚠️ 区分这两个是**诊断的核心价值**：
        /// 「规则没命中」和「规则写错了/后端没接」在界面上必须显示不同的提示。
        public var isHardFailure: Bool {
            switch self {
            case .noMatch:           return false
            case .unsupportedSyntax: return true
            case .missingHostObject: return true
            case .baseTypeMismatch:  return true
            case .jsError:           return true
            case .network:           return true
            case .other:             return true
            }
        }
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
    /// 规则不支持 / 后端没接
    case unsupported = "unsupported"
    /// 一切正常
    case ok = "ok"

    /// 从诊断推出结论
    public static func from(_ d: EngineDiagnostic) -> DiagnosisConclusion {
        guard let f = d.failure else { return .ok }
        switch f {
        case .noMatch:                      return .ruleNotMatched
        case .missingHostObject:            return .hostMissing
        case .unsupportedSyntax, .jsError:  return .unsupported
        case .baseTypeMismatch:             return .unsupported
        case .network:                      return .serverEmpty
        case .other:                        return .ruleNotMatched
        }
    }
}

/// ⭐ **求值结果** —— 值 + 诊断（诊断**永远在**，不是可选附件）。
///
/// 设计取舍：
/// - 「规则没命中」**不是错误**（兜底链里第一段没命中是正常的）⇒ 诊断的 failure = `.noMatch`
/// - 「真错误」（XPath 没实现 / 响应类型不对 / JS 后端缺失）⇒ failure 非 nil 且 `isHardFailure == true`
/// - ⇒ 调用方**必须**显式看诊断，不能只看值 —— 这是"不许静默失效"的落地方式
public struct Evaluation: Sendable {
    /// 求值结果
    public var value: RuleValue
    /// 诊断（永远有）
    public var diagnostic: EngineDiagnostic

    public init(value: RuleValue, diagnostic: EngineDiagnostic) {
        self.value = value
        self.diagnostic = diagnostic
    }

    /// 值是不是「空」
    public var isEmpty: Bool { value.isEmpty }
    /// 是不是**真错误**（区别于「没命中」）
    public var isHardFailure: Bool { diagnostic.failure?.isHardFailure ?? false }
    /// 结论分级（给 UI）
    public var conclusion: DiagnosisConclusion { DiagnosisConclusion.from(diagnostic) }
}
