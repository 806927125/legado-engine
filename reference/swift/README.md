# 参考实现（Swift）—— 对拍用

| 文件 | 来源 | 说明 |
|---|---|---|
| `AnalyzeUrl.swift` | 轻阅（qireaderlite）`QiReaderLite/Core/AnalyzeUrl.swift` | URL 规则实现，语义抄 Legado + 栖阅。**只读，不改。** |

用途：`conformance` 里的 URL 规则对拍（自研实现 vs 这份参考实现）⇒ **差异 = 待查的债**。

⚠️ 这份实现是轻阅 App 层的代码，不在 `reference/js/` 里 —— 因为它是 **Swift**，
不在 JS 引擎里，但它定义的是**同一套 URL 规则语义** ⇒ 拿来做对照正合适。
