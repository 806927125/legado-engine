import Foundation

/// **编排层错误** —— 流水线跑不动时抛的东西。
///
/// ⭐ **每个错误都要能说清「是哪一层、哪一个字段」**——
/// 「静默返回空」是本项目要消灭的头号敌人（见规格 §S-DIA）。
public enum SourceError: Error, LocalizedError, Sendable {
    /// 请求失败（网络层 / HTTP 非 2xx）
    case requestFailed(String, String)
    /// 结果为空（规则层）—— `field` 是出问题的规则字段名
    case emptyResult(String)
    /// 规则缺失（书源压根没给这条规则）
    case ruleMissing(String)
    /// 暂不支持（引擎还没实现的能力）
    case unsupported(String)
    /// 书源本身无效
    case invalidSource(String)

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let url, let message):
            return "请求失败：\(url)（\(message)）"
        case .emptyResult(let field):
            return "结果为空（\(field)）"
        case .ruleMissing(let field):
            return "规则缺失（\(field)）"
        case .unsupported(let what):
            return "暂不支持：\(what)"
        case .invalidSource(let why):
            return "书源无效：\(why)"
        }
    }

    /// **是「网络层」还是「规则层」** —— UI 上要分开显示
    public var isNetworkFailure: Bool {
        if case .requestFailed = self { return true }
        return false
    }
}
