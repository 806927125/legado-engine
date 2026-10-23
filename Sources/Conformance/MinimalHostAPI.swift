import Foundation
@testable import LegadoCore

/// **对拍用的最小宿主 API** —— 只给「纯 JS 计算」用例兜底。
///
/// ⭐ **为什么只要空实现**：
/// `requires: "js-pure"` 的用例**刻意不碰宿主 API**（只用 JS 语言本身的语义）⇒
/// 宿主方法一个都不该被调到 ⇒ 空实现正好能**证明这一点**
/// （如果某条用例误调了宿主 API ⇒ 它会拿到 null ⇒ 结果与期望不符 ⇒ 门禁立刻红 ⭐）。
///
/// ⇒ 而**需要宿主 API** 的用例（`requires: "js"`）继续保持两边都跳过
/// ⇒ 等宿主 App 实现了 `java.*` / `source.*` 再解冻。
public struct MinimalHostAPI: JSHostAPIProvider {
    public init() {}

    public func hostObject(named name: String) -> HostObject? {
        // ⚠️ **故意返回空对象**（没有方法、没有属性）⇒
        //   纯 JS 用例一旦读到 `source.xxx` / `book.xxx` ⇒ undefined ⇒ 门禁会红
        HostObject(name: name)
    }

    public func callJava(_ method: String, _ args: [JSONValue]) -> JSONValue? {
        // ⚠️ 纯 JS 用例不该调到宿主方法 ⇒ 一旦调到，返回 null ⇒ 结果不符 ⇒ 门禁红
        nil
    }
}
