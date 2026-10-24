# 真书源语料（🍅大灰狼聚合）

> ⚠️ **这里的每个字节都是站方的原文**，一个字符都没改。
> 用途：**门禁的输入**（真语料 ⇒ 引擎一改就红）⇒ 不是"示例数据"。

## 来源

- 书源包：`🍅大灰狼聚合5.9.30-轻阅适配版v2.json`（轻阅仓库 `sources/`）
- 抽取方式：只取 `jsLib` 与 `exploreUrl` 两段 ⇒ 其余规则（搜索/详情/目录/正文）不在本目录

| 文件 | 是什么 | 字节 |
|---|---|---|
| `dahulang-jsLib.js` | 站方 `jsLib`（**全局作用域**加载 ⇒ 规则要调它的 `host` / `getArguments`） | 31,961 |
| `dahulang-exploreUrl.js` | 站方 `exploreUrl`（`<js>` 块 ⇒ 返回分类数组的 JSON 文本） | 12,049 |
| `dahulang-explore-result.json` | **上面那段 exploreUrl 的真实输出**（Node 端到端跑出来的原文） | 2,639 |
| `dahulang-source-meta.json` | 这个源的名字 / 主页 / 出处 | — |

## 为什么值得单独存一份

2026-10-23 真机栽过：**发现页冒出「未分组」假分类** ⇒ 整本书打不开。
根因在**引擎**（不是站方规则的锅）：

1. **Java 兼容层**（`JavaImporter` / `Packages.*`）没注入
   ⇒ 大灰狼 jsLib 第一行 `new JavaImporter()` 抛错 ⇒ **jsLib 整个加载失败**
2. **宿主通道**（`source` / `java` / `cookie`）**必须先于 jsLib 注入**
   ⇒ 否则 jsLib 里的 `source.getVariable()` 拿不到东西
3. **JSC 的 `evaluateScript` 顶层 `var` 不进全局**（与 WebKit 不同！）
   ⇒ jsLib 必须用**间接 eval** `(0, eval)(code)` 加载

⇒ 所以门禁直接拿**真 jsLib + 真 exploreUrl** 跑 ⇒ 上面三条**任何一条回退 ⇒ 必红** ⭐

## 期望值的来路（不是拍脑袋）

- Node 端到端实测（真 jsLib + 真 exploreUrl + 同样的注入顺序）：
  **9 项** = 线路 / 模式 / 频道 / 平台 / 字数 / 状态 / 排序 / 登录大灰狼书源 / 登录番茄
- 与真机观测一致（轻阅交接文档：「发现页分类 ✅ 9 个（线路/模式/频道/平台/字数/状态/排序/登录）」）
- 其中前 7 项是站方的**筛选栏**（`type:"select"` ⇒ 栖阅契约）⇒ 引擎要拆成 `filters`
  （**不是**分类！）后 2 项带 `url` ⇒ 才是 `kinds`

## 门禁在哪

- `Tests/LegadoCoreTests/StationDahulangTests.swift` —— **沙盒可跑**
  （验分类/筛选栏拆分；不依赖 JSC）
- `Tests/LegadoCoreTests/StationDahulangJSTests.swift` —— **macOS CI 才跑**
  （真 JSC 跑真 jsLib + 真 exploreUrl ⇒ 验三个注入根因）
