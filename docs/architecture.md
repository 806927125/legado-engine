# 目标架构

> 自研引擎的六层结构 + 每层的技术选型 + 每层的**验收标准**。
> 规格见 [`legado-semantics.md`](legado-semantics.md)。

---

## 总图

```
┌─ ① 规则前端 (Rule Frontend) ───── 纯 Swift ──────────────────────┐
│    Lexer → Parser → AST（可序列化 ⇒ 可缓存 / 可预编译）             │
│    产物：RuleNode                                                  │
│    ✅ 已完成（Phase 1）                                             │
├─ ② 求值器 (Evaluator) ─────────── 纯 Swift ──────────────────────┤
│    ✅ RuleNode + EvalContext(base/book/source/vars) → RuleValue     │
│    ✅ JSONPath + 模板插值 + @put/@get + 正则净化                    │
│    ✅ 值系统两种出口统一（字段→String / 列表→[RuleValue]）          │
│    ⭐ result 语义由「基准」决定，不由调用方决定                    │
│    ⬜ JS 规则求值（等 Phase 3 接 JSC）                             │
├─ ③ DOM 层 ────────────────────── 纯 Swift ──────────────────────┤
│    ✅ SwiftSoup 后端（HTML5 容错 + Jsoup 兼容选择器）              │
│    ✅ Legado 方言（class./tag./id./text. 前缀 + 裸标签名）          │
│    ✅ 排除语法 `!N` + `:textEquals` 后置过滤                       │
│    ⬜ XPath 子集（待做）                                            │
│    ⬜ 同步 document 代理（喂给 JS）                                 │
├─ ④ JS 运行时 ────────────────── JSC / QuickJS ───────────────────┤
│    沙箱：受限全局 + 注入宿主绑定（**同步**）                       │
│    ⬜ 未开始                                                        │
├─ ⑤ 宿主适配 (Host Adapters) ───── 纯 Swift ──────────────────────┤
│    HTTP / Cookie / Storage / File / Browser / Toast / Log          │
│    全部**同步**接口                                                 │
│    ⬜ 未开始                                                        │
├─ ⑥ 编排层 (Orchestrator) ─────── 纯 Swift ──────────────────────┤
│    搜索 / 发现 / 详情 / 目录 / 正文  五条流水线                     │
│    ⬜ 未开始                                                        │
└────────────────────────────────────────────────────────────────────┘
        ↕ 诊断（EngineDiagnostic）横切 ①-⑥ —— 一等公民
```

---

## ⭐ 设计原则

### 1. 引擎内部**全同步**

| 调用 | 同步？ | 说明 |
|---|---|---|
| HTTP 请求 | ✅ | 引擎跑在自己的线程上，直接等 |
| 站方 JS（`java.ajax`） | ✅ | JSC 的 `evaluateScript` 是同步的 |
| DOM 解析 | ✅ | SwiftSoup / jsoup 是同步的 |
| **浏览器登录交接** | ❌ | **唯一异步点** —— 要等用户操作 |

⇒ **两遍跑机制在这个架构里不存在。**
轻阅为了补同步造的那一整套（录制 / 回放 / 缓存优先 / 循环上限 / 静音）**全部不需要**。

⚠️ 但「浏览器登录」这条链仍然需要**挂起/恢复**的设计：
引擎线程阻塞等 UI 线程 ⇒ 必须用 continuation 桥，不能 `Semaphore.wait()` 卡主线程。

### 2. 宿主能力**原生写**，JS 只做转发

用户铁律：「引擎能力一律用 Swift 写」。

轻阅的做法是「JS 侧实现 + postMessage 转发」⇒ 才需要「两遍跑」「同步通道」
（`window.prompt`）这一堆复杂度。自研引擎直接 `JSExport` 暴露同步方法 ⇒ 复杂度消失。

### 3. 契约用**类型**编码

```swift
enum RuleBase {
    case page(String)        // 页面级：当前页原文
    case element(DOMRef)     // 条目级：列表项
    case json(JSONValue)     // init 输出级 / JSON 对象
}
```

`result` 由 `base` 决定 ⇒ **编译期就不可能传错**。
轻阅 build206 的回归（一刀切成页原文）在这个模型里**写不出来**。

### 4. 不可控的东西要**关进小笼子**

JS 是唯一不可控的部分 ⇒ 它的接口面必须**窄到能在 Node 里 mock 出等价物**
⇒ 这样门禁主体仍然能在沙盒跑（jsdom / Node），只有极小一块需要真机验。

---

## 各层技术选型与验收

### ① 规则前端 ✅ 已完成

- **实现**：`Sources/LegadoCore/Rule/`
- **选型**：Swift，纯 Foundation
- **验收**：模式判定 19 条 + 链段分类 12 条 fixture 全过；
  `||`/`&&`/`,` 的切分只此一处实现（轻阅有三处且不一致）

⚠️ **已知债在参考实现那边**：链段里的裸标签名被当属性名（125 源 279 处）。
自研这边已按规格修对 + 双向回归锁。

### ② 求值器 ⬜

- **实现**：`Sources/LegadoCore/Evaluator/`
- **依赖**：①的 AST + ③的 DOM + ④的 JS
- **验收**：`RuleValue` 两种出口（字段→String / 列表→[RuleValue]）不许各调用点各转各的；
  JSON 对象**不得**被隐式 stringify（§S-JSON-02）；`{title,url}` 形状的对象**标题不得被吃掉**（§S-JSON-06）

### ③ DOM 层 ✅ 部分（2026-10-23）

- **已做**：
  - `DOMNode` 协议 + `SwiftSoupNode` 实现（核心层纯 Foundation，实现可换）
  - `HeadTranslator`（`prefixToCss` 语义）+ `SegmentTranslator`（KW 分类）**分流**
  - `LegadoSelector`（链求值）+ `PseudoFilter`（后置伪类）
  - 排除语法 `!N`、索引 `:0` / `[-1]`、`text.` 完全相等
- **HTML 解析 ⇒ SwiftSoup**（HTML5 容错 + Jsoup 兼容选择器）—— **不自研**
- **XPath ⇒ 自研"够用"子集**（`//tag`、`//tag[@a='v']`、`//tag[n]`）—— **待做**
  - 理由：可控 + 沙盒可验 + **不支持的语法要明确报错**（比静默给错结果值钱得多）
  - 风险：碰到冷门 XPath 会失败 ⇒ **必须有回落路径**

### ④ JS 运行时 ⬜

| | JSC（Apple 系统库） | QuickJS（C, MIT） | 自研解释器 |
|---|---|---|---|
| 同步 | ✅ | ✅ | — |
| iOS 集成 | 零配置，`JSExport` | 要编 C + 写 C 桥 | — |
| ES 版本 | ES6+ 完整 | ES2020 大部分 | — |
| 你拥有它 | ❌ | ✅ | ✅ |
| 风险 | Apple 改（极低） | 自己维护编译 | 荒谬 |

⇒ **v1 用 JSC，抽象成 `JSExecutor` 协议**；要 100% 自有（离线/内网/审计）时换 QuickJS。

**必须注入的同步宿主绑定**：
`java.*` / `source.*` / `book.*` / `cookie.*` / `cache.*` / `infoMap.*` / `document.*` / `baseUrl` / `result` / `key` / `page`

⚠️ **`result` 必须按基准分层**（§S-RES）—— 这是最容易错的一处。
⚠️ **每个源一个 JSContext** ⇒ 换源不串台（栖阅的 `purgeUnexpectedGlobals` 那一层，
自研里用「每源独立 context」天然解决）。

### ⑤ 宿主适配 ⬜

纯 Swift，同步接口。HTTP 用 URLSession 的同步 API 或自建封装
（⚠️ URLSession 的 `data(for:)` 是 async ⇒ 需要同步封装或自建线程池 + 等待）。

### ⑥ 编排层 ⬜

五条流水线：搜索 / 发现 / 详情 / 目录 / 正文。
每条都返回**结构化诊断**（`EngineDiagnostic`）⇒ UI 能区分
「服务器没数据」/「规则没命中」/「站方返回了占位」三态。

---

## 迁移策略：影子模式

不能一步到位。关键机制：

```
老实现 → 结果给用户看
新实现 → 结果不给用户看，只跟老实现对拍，差异写日志
         连续 N 次一致（且覆盖 N 种规则形态）→ 切默认
         出错 → 回落老实现
```

⇒ **任何时候宿主都能用**。

对拍基准 = `conformance/fixtures/semantics-cases.json` +
真实书源的端到端活体用例（发现→详情→目录）。

---

## 与轻阅的关系

- 本项目**不依赖**轻阅，也不改轻阅。
- `reference/js/` 只是轻阅引擎的**只读快照**，用来对拍。
- 自研引擎完成后，轻阅可以：
  - **继续用**自己的 JS 引擎（现状，不受影响）
  - 或**切到**自研引擎（`LegadoCore` 纯 Foundation，可以直接被轻阅的 `Core/` 引用）
- 轻阅那边已知的债（裸标签名、flatten 吃标题、排除语义、诊断说谎…）**在本项目里都已按规格修对**，
  可以**回灌**给轻阅，也可以不回灌。

---

## 风险清单

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| 1 | **HTML 解析保真度** | 站方源对畸形 HTML 极敏感 | 用 SwiftSoup；门禁用真实站方 HTML |
| 2 | **XPath 子集不够** | 冷门 XPath 源失败 | 明确报错 + 回落路径（不许静默给错结果） |
| 3 | **JSC ↔ 站方怪写法** | 站方 jsLib 的怪写法行为可能不同 | 自带 lint 层（未声明变量 / 对象字面量重复成员） |
| 4 | **站方源的长尾** | 永远有新的怪规则 | 引擎要能**明确报错**而不是静默返回空 |
| 5 | **迁移期双轨** | 语义分裂 | 单一真源（规格）+ 对拍 fixture |
| 6 | **JSC 沙盒盲区** | 那部分只能真机验 | 把 JSC 接口面缩到能 mock 的程度 |
