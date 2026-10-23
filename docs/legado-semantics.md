# Legado 规则语义规格（轻阅引擎）

> **性质**：这是**规范**，不是笔记。每一条规定都必须是**可执行的**——要么有门禁钉死，要么明确标注「未覆盖」。
> **目的**：
> 1. 现在的轻阅引擎是「跑得通的实现」，不是「有定义的东西」。这份文档把实现反推成**规范**。
> 2. 将来重写引擎（大引擎 / JSC / Swift 规则引擎）时，这份文档是**验收标尺**，不是参考读物。
> 3. 每条语义都带 `id`，`test/fixtures/semantics-cases.json` 按 `id` 引用，
>    `test/semantics-conformance.test.js` 跑出**现状符合度报告**（哪些已对、哪些错、哪些没实现）。
>
> **证据来源**（按可信度排序）：
> - 🟢 源码事实（`QiReaderLite/Resources/engine/*.js`）——实现即证据
> - 🟢 栖阅《引擎反推》材料（符号表 + 字面量 + 随包 JS 兼容层）——见 `栖阅-轻阅-引擎对账.md`
> - 🟡 Legado 安卓端行为（`com.gy.reader` 的 `AnalyzeUrl` / `AnalyzeRule` / `SourceRule`）
> - 🟡 站方书源实测（125 源包活体体检、`sources/`）
> - 🔴 推断（**不许当规范用**，只能当假设）
>
> **术语**：
> - **基准（base）**—— 规则求值时的输入对象。分四类：**页面级**（当前页原文）、**条目级**（列表项）、
>   **init 输出级**（`ruleBookInfo.init` 的产物）、**元素级**（DOM 节点）。
> - **result** —— 站方 JS 规则里那个 `result` 变量。**它的类型由基准决定，不由调用方决定**（见 S-RES）。
> - **规则原文** —— 书源 JSON 里那条规则字符串。

---

## 0. 读法

每条语义长这样：

```
### S-XXX-NN 标题
**规范**：一句话说清「应该是什么行为」。
**依据**：🟢 源码位置 / 🟡 栖阅符号 / 🟡 Legado 行为。
**现状**：当前实现的实际行为（可能 = 规范，也可能 ≠ 规范）。
**门禁**：`test/xxx.test.js` 里的用例名，或 `semantics-cases.json` 的 case id。
```

⚠️ **「现状」和「规范」不一致的地方，就是债。** 报告见 `docs/现状符合度报告.md`。

---

## 1. S-CLS 规则模式判定

> 一条规则字符串**属于哪种模式**，决定它被谁求值。判定顺序**严格自上而下**，先匹配先赢。

### S-CLS-01 显式 JS 模式
**规范**：规则以 `@js:` 或 `@JS:` 开头 → **JS 模式**。
**依据**：🟢 `rule-analyzer.js:73-74`；🟡 栖阅 `RuleMode.js`。
**现状**：✅ 一致。

### S-CLS-02 `<js>` 块
**规范**：规则以 `<js>` 或 `<JS>` 开头 → **JS 模式**（整块当 JS 代码，不是选择器）。
**依据**：🟢 `rule-analyzer.js:75`；🟡 栖阅 `AnalyzeRule.isJsBlock()`。
**现状**：✅ 一致。
⚠️ 栖阅的《书源制作文档》说「没有 `<js>` 块」是**错的**（那是二进制搜不到字面量的推断，被符号表推翻）。

### S-CLS-03 正则模式
**规范**：规则以 `##` 开头 → **REGEX 模式**。
**依据**：🟢 `rule-analyzer.js:76`。
**现状**：✅ 一致。

### S-CLS-04 显式 CSS 模式
**规范**：规则以 `@CSS:` 开头（**大小写不敏感**）→ **SELECTOR 模式**。
**依据**：🟢 `rule-analyzer.js:78`。
**现状**：✅ 一致。

### S-CLS-05 二次解析
**规范**：规则以 `@@` 开头 → **SELECTOR 模式**（且 `@@` 前缀被剥掉）。
**依据**：🟢 `rule-analyzer.js:79` + `stripModePrefix`。
**现状**：✅ 一致。

### S-CLS-06 显式 XPath
**规范**：规则以 `@XPath:` 开头（**大小写不敏感**）→ **XPATH 模式**。
**依据**：🟢 `rule-analyzer.js:80`。
**现状**：✅ 一致。

### S-CLS-07 显式 JSONPath
**规范**：规则以 `@Json:` 开头（**大小写不敏感**）→ **JSONPATH 模式**。
**依据**：🟢 `rule-analyzer.js:81`。
**现状**：✅ 一致。

### S-CLS-08 响应是 JSON 且规则像 JSONPath
**规范**：`ctx.isJSON == true` **且**规则以 `$` 开头 → **JSONPATH 模式**。
**依据**：🟢 `rule-analyzer.js:88`。
**现状**：✅ 一致。
⚠️ **必须同时要求「规则以 `$` 开头」**。少了这个条件，JSON 响应里的值类型规则
（`{{$.grade}}分`、`{{java.put(...)}}`）会被硬塞进 JSONPath 解析器 → 一律返回空。

### S-CLS-09 规则自带 JSONPath 特征
**规范**：规则以 `$.` 或 `$[` 开头（可含前导空白）→ **JSONPATH 模式**。
**依据**：🟢 `rule-analyzer.js:89`。
**现状**：✅ 一致。

### S-CLS-10 `result.` 前缀 = 相对当前结果
**规范**：规则以 `result.` 或 `result[` 开头（可含前导空白）→ **JSONPATH 模式**，
且求值前把 `result.` 改写成 `$`（**每个 `||` 分段都要改**）。
**依据**：🟢 `rule-analyzer.js:92` + `rewriteResultPath`（:1533）；🟡 Legado 允许这种相对写法。
**现状**：✅ build214 修（125 源里 130 处这种写法）。
⚠️ 以前不认 ⇒ 落进「选择器」分支 ⇒ **0 命中**。

### S-CLS-11 XPath 特征
**规范**：规则以 `/` 开头 → **XPATH 模式**（Legado 注释：XPath 特征很明显，无需识别标头）。
**依据**：🟢 `rule-analyzer.js:94`。
**现状**：✅ 一致。

### S-CLS-12 HTML 模式
**规范**：规则以 `<` 开头 → **HTML 模式**（整段当 HTML 片段转文本）。
**依据**：🟢 `rule-analyzer.js:95`。
**现状**：✅ 一致。

### S-CLS-13 兜底
**规范**：以上都不匹配 → **SELECTOR 模式**。
**依据**：🟢 `rule-analyzer.js:96`。
**现状**：✅ 一致。

### S-CLS-14 模式判定在**去掉尾部之后**要再判一次
**规范**：`evalOne` 拆掉 `##…##` / `<js>…</js>` 尾部后，**必须重新判定模式**；
`result.` 前缀的改写也必须在这一步做。
**依据**：🟢 `rule-analyzer.js:852-860`。
**现状**：✅ 一致。

---

## 2. S-RES `result` 的语义分层 ⭐⭐⭐

> **这是整份规格里最要紧的一条。** 轻阅在这里栽过两次：
> build206（一刀切成「当前页原文」⇒ `result.book_id` 恒 undefined ⇒ 整本书崩）
> 和 build213（改成按基准分流 ⇒ 修好）。

### S-RES-01 条目级 / init 输出级
**规范**：基准是**普通对象**（非数组、无 `nodeType`）→ `result` = **那个对象本身**。
**依据**：🟢 `rule-analyzer.js:1070-1072`（`jsResultOf`）。
**现状**：✅ build213。
**站方实例**（🍅大灰狼）：`let book_id = result.book_id;` —— `result` 必须是那条书籍记录。

### S-RES-02 页面级
**规范**：基准是 **document**（`nodeType == 9`）→ `result` = **当前页原文**（`ctx.raw`，HTML 源码），
**不是** `dom.textOf(node)` 的纯文本。
**依据**：🟢 `rule-analyzer.js:1073-1076`。
**现状**：✅ build213。
**站方实例**（🍒NovelHub）：`var s = String(raw); s.match(/<div class="book-like">…/)`。
⚠️ 给纯文本 ⇒ 正则永远匹配不上 ⇒ 列表 0 本。

### S-RES-03 元素级
**规范**：基准是 DOM 元素（`nodeType` 存在且非 9）→ `result` = 该元素的文本。
**依据**：🟢 `rule-analyzer.js:1077`。
**现状**：✅ 一致。

### S-RES-04 基准为空
**规范**：基准为 null/undefined → `result` = `ctx.raw`（若在）否则 `''`。
**依据**：🟢 `rule-analyzer.js:1069`。
**现状**：✅ 一致。

### S-RES-05 标量 / 数组
**规范**：基准是字符串或数组 → `result` = 基准本身。
**依据**：🟢 `rule-analyzer.js:1078`。
**现状**：✅ 一致。

### S-RES-06 ⛔ 禁止一刀切覆盖
**规范**：`jsScope` 构造作用域时，`result` **只能**由 `jsResultOf(base, ctx)` 决定。
**任何调用点都不得再把 `result` 覆写成别的值。**
**依据**：🟢 `rule-analyzer.js:912`（源码里明确写了「这里不要再覆盖」）。
**现状**：✅ build213 修掉了 build206 引入的一刀切。
⚠️ 违反这条的症状极难定位：`JSON.stringify` 会**静默丢掉 undefined 的键**，
载荷只剩 `{"tab":"小说","url":""}` ⇒ 看着像站方的锅。

### S-RES-07 站方 JS 的 `result` 与宿主的 `resultNode` 是两回事
**规范**：JS 作用域里同时提供 `result`（按 S-RES 分流）和 `resultNode`（**原始基准对象**，不分流）。
**依据**：🟢 `rule-analyzer.js:1087`。
**现状**：✅ 一致。

---

## 3. S-SCP 作用域与宿主对象传递

> 这一整节的症状都是**静默失效**：站方 JS 抛个看不懂的错，宿主 catch 掉，界面上什么都不显示。

### S-SCP-01 `raw` = 当前页原文
**规范**：JS 作用域必须提供 `raw` = 当前内容页的**原始文本**（HTML 源码）。
**依据**：🟢 `rule-analyzer.js:1108-1111`；站方 🍒NovelHub 大量使用。
**现状**：✅ build206 修。
⚠️ 以前根本没给 `raw` ⇒ `String(undefined)` = `"undefined"` ⇒ 基于 raw 的正则**永远匹配不上**。

### S-SCP-02 `$` = 当前结果的 JSON 化视图
**规范**：JS 作用域提供 `$`（Legado 惯用名），语义 = 对当前基准做 JSONPath 取值。
**依据**：🟢 `rule-analyzer.js:1086`。
**现状**：✅ 一致。

### S-SCP-03 `source` 必须是**包过 API 的对象**
**规范**：传给站方 JS 的 `source` 必须带 `getVariable/setVariable/getLoginInfo/…`。
裸对象 ⇒ 站方一调就 `TypeError` ⇒ **整条规则静默失效**。
**依据**：🟢 `rule-analyzer.js:1113`（`QR.wrapSource`）；🟡 聚合源实测。
**现状**：✅ build146 修。

### S-SCP-04 `book` 必须是**包过 API 的对象**，而且**必须传**
**规范**：
① `book` 存在时必须带 `getVariable/setVariable/readConfig/…`；
② **调用方（App 侧）必须把 book 传进来**——站方 `ruleToc.chapterList` / `ruleContent.content`
**第一句**就可能是 `book.getVariable('custom')`，不给就抛
`Cannot read properties of undefined (reading 'getVariable')` ⇒ 整条规则静默失效。
**依据**：🟢 `rule-analyzer.js:1115`；🟡 build161 实测（目录 2566 章 vs 0 条）。
**现状**：✅ build161 修（`SourceService.toc/content` 加 `book` 参数，6 个调用点全传）。

### S-SCP-05 `document` 必须指向**当前基准文档**
**规范**：站方 `@js:` 里直接 `document.querySelectorAll` 时，`document` 必须是**当前列表页**的文档，
不是引擎自己的空页面。
**依据**：🟢 `rule-analyzer.js:1092` + `ownerDocOf`（:1120）。
**现状**：✅ 一致。

### S-SCP-06 `java` 必须能回退到「当前结果」
**规范**：JS 作用域里的 `java.getString('$.字段')` 应当能对**当前基准**求值。
**依据**：🟢 `rule-analyzer.js:1090` + `ruleJava`（:1024）。
**现状**：✅ 一致。

### S-SCP-07 作用域必须有 `key`
**规范**：JS 作用域必须提供 `key`（站方 jsLib 用得勤）。
**依据**：🟢 聚合源实测；`makeScope`（:178）。
**现状**：✅ build146 修。

### S-SCP-08 `baseUrl` = 当前页 URL
**规范**：`baseUrl` 是**当前内容页的 URL**（不是书源首页）。
**依据**：🟢 `rule-analyzer.js:1094`。
**现状**：✅ 一致。
⚠️ 站方靠 `baseUrl.indexOf("aaccoo.com")` 判断平台 ⇒ 这条错了整个站方逻辑就错。

---

## 4. S-ORD 字段求值顺序

### S-ORD-01 有 `@put`/`@get` 时，字段必须**按声明顺序**求值
**规范**：一个书对象（book / chapter）的多个字段，若任一字段含 `@put`/`@get`，
**必须按 JSON 里的声明顺序**依次求值，不得并行。
**依据**：🟢 `engine.js:1029` `evalFields`（三处调用：`extractOneBook` / `bookInfo` / `collectChapters`）；
🟡 build214 第八项缺口（红薯阅读 `.../bid//version/...` ⇒ 目录 0 章）。
**现状**：✅ build214 修。
⚠️ 以前并行 ⇒ `tocUrl` 可能在 `name` 之前跑 ⇒ 变量还没存 ⇒ URL 里是空的。

---

## 5. S-JSON JSONPath 与列表

### S-JSON-01 命中数组 ⇒ 摊平**一层**
**规范**：JSONPath 命中结果若是「单个数组」→ 返回**数组的元素**（**只摊一层**）。
**依据**：🟢 `jsonListOf`；🟡 Legado 语义；🟡 build160 实测（服务器直连 10 本 vs 引擎出 1 本）。
**现状**：✅ build160 修。
⚠️ 命中数组不摊平 ⇒ 引擎把**整个数组当成一本书** ⇒ `$.book_name` 取不到 ⇒ 书全被丢。

### S-JSON-02 JSON 对象**不得**被 `stringify` 成字符串
**规范**：JSONPath 命中**对象**时，保留对象原样。
**依据**：🟢 `evalJsonPathList`（build161）；⚠️ 通用 `flatten` 是给 DOM/标量用的，对 JSON 对象会 `JSON.stringify`。
**现状**：⚠️ **部分修复**——列表路径（`evalJsonPathList`）✅ 已保对象；
但**单值路径**（`evalJsonPath`）末尾仍走 `flatten` ⇒ 见 S-JSON-06。
⚠️ 曾经把章节对象 stringify 成字符串 ⇒ 目录条目全废。

### S-JSON-07 ⭐ `.[…]` = **方括号步骤**（`$.[*]` / `$.[-1].title`）
**规范**：`.[x]` 与 `[x]` 等价 —— 点后面紧跟方括号 ⇒ 照走方括号步骤。
**依据**：🟢 125 源实测（**16 处**用这种写法：`.data[*]` / `.[-1].title` / `.[*]`）。
**现状**：✅。

⚠️ **这条是 125 源体检量出来的**：以前 `parse` 遇到 `.` 后面紧跟 `[` ⇒ 名字收不到字符 ⇒
`return nil` ⇒ 规则被判「JSONPath 不支持」⇒ **整条规则静默失效**。

### S-JSON-06 ⛔ **债**：`flatten()` 吃掉了 `{title, url}` 形状对象的标题
**规范**：JSON 对象被摊平时，**标题必须保留**。
**依据**：🟢 `rule-analyzer.js:702-712`（`flatten` 的 `{text,title}` + `{url,href}` 分支）；
🟡 沙盒实测（2026-10-23）。
**现状**：❌ **标题丢失**。

**机理**（`flatten` 的形状分支）：
```js
if (v.text !== undefined || v.title !== undefined) {
  var s = v.text !== undefined ? v.text : v.title;   // s 是【字符串】
  if (v.url || v.href) {
    return [dom.textOf(s) + '\t' + dom.absolutize(...)];   // ← dom.textOf(字符串)
  }
  …
}
```
`dom.textOf(el)` 读的是 `el.textContent` ⇒ 传**字符串**进去 ⇒ `undefined` ⇒ 返回 `''`
⇒ 结果变成 `"\tu1"`（**标题整段没了**，只剩一个制表符和 URL）。

**实测**：`evalOne('$.item', {item:{title:'章节名', url:'u1'}})` → `["\tu1"]`（应为 `["章节名\tu1"]`）。

**影响面**：
- ❌ `evalJsonPath`（单值路径，`rule-analyzer.js:1250`）——**主路径**
- ❌ `evalOne` 末尾的 `flatten`（`:947`）
- ✅ `evalJsonPathList`（列表路径）不 flatten ⇒ 列表**不受影响**
⇒ 所以症状是「**单值规则拿到对象时标题没了**」，列表看着正常 ⇒ 极具迷惑性。

**修法方向**：`dom.textOf(s)` 之前先判类型（`typeof s === 'string' ? s : dom.textOf(s)`），
并且**排除逻辑要跟 S-JSON-02 对齐**（对象不得被无条件 stringify）。

### S-JSON-03 `result.` 前缀改写要覆盖**每个 `||` 分段**
**规范**：`rewriteResultPath` 对 `a || b` 形式的每一段都要把 `result.` 改成 `$`。
**依据**：🟢 `rule-analyzer.js:1533`。
**现状**：✅ build214 修。

### S-JSON-04 JSONPath 列表支持 `a||b` 兜底
**规范**：`jsonPathListOf` 支持用 `||` 给 JSONPath 列表加兜底。
**依据**：🟢 build214 顺带修的。
**现状**：✅（链结构本身）。

⚠️ **已知差异（待定项）**：`@html` 的语义
| | `@html` | `@outerHtml` |
|---|---|---|
| Legado / Jsoup | **innerHTML** | outerHTML |
| 轻阅 `valueOf` | **outerHTML** ❗ | outerHTML |
| 本项目 | **innerHTML**（按 Legado） | outerHTML |

⇒ 轻阅把 `html` 和 `outerhtml` **都映射成 outerHTML** ⇒ 与 Legado 不一致。
⇒ 本项目按 **Legado 语义**实现（`html` = innerHTML）；对拍时会标出这条差异。

⚠️ **另**：`text` / `ownText` / `html` / `outerHtml` / `all` / `content` / `href` / `src` 是**取值模式**，
**不是属性名**；`href/src/action/data-src/poster` 虽是属性，但取值时要**绝对化**。

### S-JSON-05 列表规则的复合形态
**规范**：列表规则可以写成 `<js>…</js>$.data.books`。
求值时**必须**先用 `splitJsWithTail` 拆成「JS 体 + 尾部选择器」，跑完 JS 再用尾部取值；
**不得**把整串当 JS eval（会得到 `Unexpected token '<'`）。
**依据**：🟢 `rule-analyzer.js:893` + `splitJsWithTail`（:1149）；🟡 build211/214（七猫/红薯/晋江…）。
**现状**：✅ build211/214 修。
⚠️ 症状差异：目录那条路早支持复合规则、发现这条路不支持 ⇒ 现象是
**「目录能出、发现出不来」** ⭐（极具迷惑性）。

---

## 6. S-CMP `<js>` 块的处理细节

### S-CMP-01 `<js>` 块**不能按行切**
**规范**：含换行的 `<js>…</js>` 必须整块处理，不能按行切（切了会腰斩成 `"<js>"`）。
**依据**：🟡 聚合源实测（`Unexpected token '<'`）。
**现状**：✅ build146 修（`isBlockRule`）。

### S-CMP-02 `<js>` 块**不能按 `||` 拆**
**规范**：站方代码里本来就有 `result.tab || '小说'` 这种 JS 运算符，按 `||` 拆会炸。
**依据**：🟡 聚合源实测。
**现状**：✅ build146 修。

### S-CMP-03 语法错 ⇒ 整段当表达式重试
**规范**：JS 规则求值失败时，若错误是**语法错**，应把整段当**表达式**重试一次
（`return (…);` 形态）。
**依据**：🟢 栖阅 cstring 原文（`Function("return (" + __script + ");")`）；
🟢 轻阅 build167 已照搬。
**现状**：✅ build167 修。

### S-CMP-04 `<js>` 块取**完成值**
**规范**：`<js>` 块的求值结果 = 块的**完成值**（`try{…; result;}` 语义）。
**依据**：🟢 栖阅 cstring；🟡 大灰狼靠这个。
**现状**：✅ 一致（大灰狼行为一致）。

### S-CMP-05 `@js:` 规则取 `result` 变量
**规范**：`@js:` 形态的规则只认 `result` 变量。
**依据**：🟢 栖阅 cstring（`Function(__script + "\n;return (typeof result !== 'undefined') ? result : undefined;")`）。
**现状**：⚠️ 轻阅取**完成值**（更宽松）。**故意保留宽松**（`栖阅-轻阅-引擎对账.md` §1 判定）。
⇒ 这是一条**已知差异**，不是 bug。新引擎应实现成「先取 `result`，取不到再取完成值」。

---

## 7. S-EXC 排除语法

### S-EXCL-01 `!N` = 排除**第 N 个**（0-based），不是「排除前 N 个」
**规范**：规则值的后缀 `!N` 表示**排除结果集里索引为 N 的那一个**（0-based）。
多个索引用 `:` 分隔：`!0:1:2:9` = 排除第 0、1、2、9 个。
**依据**：🟡 125 源实际用法（`ruleToc.chapterList`: `id.list@tag.dd!0:1:2:…:9`；
`ruleSearch.bookList`: `ul.clearfix@tag.li!0`；`ruleExplore.bookList`: `tbody@tr!0`）。
**现状**：⚠️ **语义对，位置不完整**（见 S-EXCL-02）。
⚠️ 以前完全不支持 ⇒ 这类规则一律 0 命中（build214 才补上）。
⚠️ **我曾把这条写成「排除前 N 个」——错的**。`!0` 是「排除**第 0 个**」，
不是「排除 0 个」也不是「排除前 0 个」。这条的准确语义是 2026-10-23 逐条比对 125 源
实际用法 + 沙盒实测才定下来的。

### S-EXCL-02 排除在**链中段**是生效的（我曾误判为债）
**规范**：`!N` 在选择器链的**任意一段**都生效。
**依据**：🟡 125 源实际用法。
**现状**：✅ **排除语法本身没问题**（2026-10-23 沙盒逐位置实测）：

| 位置 | 例子 | 实测 | 生效？ |
|---|---|---|---|
| **头部**（第一个 `@` 之前） | `span!0@text` | 2 → 1 | ✅ |
| **链中段**（带 `tag.` 前缀） | `.tips@tag.span!0@text` | 2 → 1 | ✅ |
| **链尾段** | `tbody@tag.tr!0` | 2 → 1 | ✅ |
| **链中段**（**裸**标签名） | `.tips@span!0@text` | 2 → 2 | ❌ |

⇒ 最后一行**不是排除语法的锅**，而是 **S-SEL-06 的连带后果**：
裸标签名那一整段被当成了属性名（连 `!0` 一起）⇒ 链断 ⇒ 排除自然也没了。
⇒ **修 S-SEL-06 时，这条会跟着好。**

⚠️ 我曾把这条写成「链中段不生效 = 独立债」——**错了**，已修正。

---

## 8. S-SEL 选择器方言

### S-SEL-01 `text.` = 文本**完全相等**
**规范**：`text.XXX` 匹配的是**文本完全等于** `XXX` 的元素，**不是**「包含」。
**依据**：🟡 build214 第六项（`text.查看目录` 曾匹配到 `<title>`，因为标题里也含这四个字 ⇒ 抓到 11 个元素 ⇒ 目录只有 1 章）。
**现状**：✅ build214 修（新增 `:textEquals` 伪类）。

⚠️ **「完全相等」比的是元素的【完整文本】（含所有后代）** ⇒ **祖先元素也可能命中**：
`<body>里只有一个 <a>查看目录</a></body>` ⇒ `<a>`、`<body>`、`<html>` 的完整文本都等于「查看目录」⇒ **三个都命中**。
⇒ 真实页面里通常有兄弟节点，祖先文本 ≠ 目标值 ⇒ 只有目标元素命中（125 源实测符合预期）。
⇒ 但**这是「静默多命中」的来源** —— 用 `text.` 的规则要意识到可能拿到祖先。

### S-SEL-02 class 的值可以带空格
**规范**：`class.clearfix chapter-list` ⇒ 匹配**同时**有 `clearfix` 和 `chapter-list` 两个 class 的元素。
**依据**：🟡 125 源实测（40 处）。
**现状**：✅ build214 修（空格一律当**并列的 class** `.a.b`）。
⚠️ 以前把空格当**后代选择器** ⇒ 0 命中。

⭐ **零误伤已用 125 源实测坐实**（2026-10-23）：
- 「`class.X 空格 Y`」（并列 class）**40 处** ⇒ 全部要求**并列**语义
- 「`tag.cls 空格 tag`」（纯 CSS 后代，如 `dl.B dd` / `ul.MLlist li` / `a.book-cover img`）**50 处**
  ⇒ 仍要求**后代**语义
⇒ 判据 = **有没有 `kw.` 前缀**：带前缀 ⇒ 空格当并列 class；不带 ⇒ 空格保持标准 CSS 后代。
⇒ 实现见 `HeadTranslator`（`prefixToCss` 语义）：**真实标签当前缀时，值整体当类名**
（`dl` + `.` + `B dd` ⇒ `dl.B dd` ⇒ 后代语义保住了）。

### S-SEL-03 Legado 方言前缀
**规范**：支持 `class.X` / `tag.X` / `id.X` 三种前缀。
**依据**：🟢 参照 Android 侧 NovelReader 的 `DefaultRules.kt`；🟡 Legado 默认规则语法。
**现状**：✅（`dom.resolve` 支持）。

### S-SEL-04 链式选择
**规范**：`@` 分隔的链式选择，每段在上一段结果内选；末段可带取值模式
（`text` / `textNodes` / `ownText` / `html` / `outerHtml` / `all` / `content` / `href` / `src` / 其它当属性名）。
**依据**：🟢 `dom.resolve`；🟡 Legado 默认规则语法。
**现状**：✅。

### S-SEL-05 索引
**规范**：支持 `em.0`（第 0 个）/ `tag.div[-1]`（最后一个）/ `.0`（当前列表第 0 个）。
**依据**：🟡 Legado 默认规则语法。
**现状**：✅。

### S-SEL-06 ⛔ **债**：链段里的**裸标签名**必须当**子元素选择器**
**规范**：链段（`@` 后面那一段）若是一个**裸 HTML 标签名**（`li` / `a` / `img` / `span` / `p` / `dd` / `h2` / `ul` / `tr` …），
它表示「**在上一段结果内找这种子元素**」。

**只有 Legado 的属性白名单**（`text` `html` `outerHtml` `ownText` `all` `content` `href` `src` `title` `value` `class` `id` `alt` `name` `type`）
才是属性后缀。

**依据**：🟡 125 源实测（**279 处，涉及 60 个源 = 48%**）——这是站方最常见的链写法。
**现状**：❌ **裸标签名被当成了属性名** ⇒ 链在那一段**断掉** ⇒ 取到的是**父元素整体**。

**实测对照**：
```
class.catalog_ls@li        → ["第一章第二章"]   ← 错！这是 <ul> 自己的文本（1 个节点）
class.catalog_ls@tag.li     → ["第一章","第二章"] ← 对
class.book_about@dd@text    → ["简介内容"]       ← 侥幸对（父元素只有一个 dd，文本碰巧一样）
```

**机理**（`jsoup-compat.js:218`）：
```js
if (dot >= 0 && (KW[kw] || isHtmlTag(kw))) {   // ← 必须有「kw.」前缀才算子选择器
  chain.push({ kind: 'sub', … });
} else {
  chain.push({ kind: 'attr', name: val || p }); // ← 裸名一律当属性 ❗
}
```
裸名没有 `dot` ⇒ 走 else ⇒ 当属性 ⇒ 链断。

**症状对照（125 源体检的三大症状）**：

| 站方规则 | 字段 | 现在得到 | 应该得到 | 症状 |
|---|---|---|---|---|
| `class.catalog_ls@li`（神马小说） | `ruleToc.chapterList` | 1 个 `<ul>`（章名全拼一起） | N 个 `<li>` | **目录只有 1 章** ⭐ |
| `class.searchList@li`（梧桐中文） | `ruleSearch.bookList` | 1 个 `<ul>` | N 本书 | **搜索只出 1 本** ⭐ |
| `.lis@li\|\|.topli@li`（读读小说） | `ruleExplore.bookList` | 1 个节点 | N 本书 | **发现页出不来** ⭐ |
| `.sidebar@img@src`（过期杂志） | `ruleBookInfo.coverUrl` | `div` 的 `src` 属性（空） | `<img>` 的 src | **封面空白** |
| `class.top_main.-1@a@text`（安之原创） | `ruleBookInfo.lastChapter` | 整个区块的文本 | 最后一条链接的文本 | **最新章节乱** |

**修法方向**：`parseChain` 的 else 分支要分流 ——
裸名在**属性白名单**里 ⇒ `attr` 步；否则 ⇒ `sub` 步（按标签名找子元素）。
⚠️ **必须回归 125 源的两种链尾排除用法**（`!0` / `!0:1:2:…`）和 `@get:{k}` / `@text` / `@html` 等属性后缀，
别把属性后缀一起改坏。

**风险提示**：这条一改，**60 个源的解析结果会变**（从 1 条变 N 条）⇒ 必须配活体回归，
不能只看离线用例绿不绿。

---

## 9. S-PUT `@put` / `@get`

### S-PUT-01 内嵌写法必须支持
**规范**：`@put:{k:v}` / `@get:{k}` 可以**内嵌**在规则或 URL 里，
不要求「整条规则就是这个形式」。
**依据**：🟡 125 源实测（11 处，7 个源）；🟢 build214 第二项。
**现状**：✅ build214 修。
⚠️ 以前只认整条规则形态 ⇒ `'$.bookName@put:{xid:x_id}'` 全废。
**站方实例**：`'https://x/read/@get:{xid}/{{$.num}}'`。

### S-PUT-02 `@put` 的值怎么求值
**规范**：`@put:{k:v}` 里的 `v` 支持 `$.a`（JSONPath）/ 裸路径 / `a||b` 兜底。
**依据**：🟢 `evalVarExpr`（:1485）+ `lookupPath`（:1500）。
**现状**：✅ build214 修。

### S-PUT-03 ⛔ **债**：`@get:` 内嵌在 **URL 里** ⇒ 轻阅也不替换
**规范**：`https://x/read/@get:{xid}/1.html` 这种「URL 里内嵌 `@get:`」⇒ **必须替换成变量值**。
**依据**：🟡 站方实例（125 源实测，`@get:` 内嵌共 11 处）。
**现状**：❌ **轻阅也不替换**（沙盒实测：`https://x.example/read/@get:{xid}/1.html`
⇒ 轻阅得到 `https://x.example/read//1.html`，变量被替换成空串）。
⚠️ 这跟「整条规则就是 `@get:{k}`」是**两条不同的路** —— 轻阅只处理了后者。
⇒ 自研实现**已按规格修对**（`VarStore.apply` 对整条规则做正则替换，URL 也在内）✅
⇒ 这条差异被 fixture 的 `put-01` 用例钉住。

### S-PUT-03b 存了要能取到
**规范**：`@put` 存的变量，后续规则的 `@get` / `{{$.var}}` 必须能取到。
**依据**：🟡 站方 `x_id` 这类参数就是靠这个传的。
**现状**：✅。

---

## 10. S-RGX 正则

### S-RGX-01 格式
**规范**：`##pattern##replace##replace2…`。
- 只有一组 ⇒ **纯提取**（取第 1 个捕获组，没有捕获组则取整体）
- 有 replace ⇒ 对**匹配到的整段**做替换（支持 `$1..$n`）
- `##` 后面可以有多个替换，依次执行
**依据**：🟢 `parseRegexRule`（:124）+ `applyRegex`（:141）。
**现状**：✅。

### S-RGX-02 看着像 URL 才绝对化
**规范**：正则产出的片段，**只有看着像 URL**（`http:` / `ftp:` / `file:` / `//` / `/` / `./` / `../`）时才做绝对化。
**依据**：🟢 `looksLikeURL`（:137）。
**现状**：✅。
⚠️ 否则正则抓到一句正文也会被当 URL 编码掉。

### S-RGX-03 正则模式不参与元素选择
**规范**：REGEX 模式只作用于**文本**，不返回 DOM 元素。
**依据**：🟡 Android 侧 NovelReader `RuleEngine.selectElements` 里 `@regex:` → `emptyList()`。
**现状**：✅（`evalOne` 的 REGEX 分支走 `applyRegex(text, …)`）。

### S-RGX-04 base64 载荷被 URL 动过手脚也要能解
**规范**：`hexDecodeToString` 对被 URL 编码/转义过的 base64 串要能还原
（`%2B`→`+`、`%2F`→`/`、`%3D`→`=`、`-`→`+`、`_`→`/`、**空格→`+`**），
解不出来时**明确失败**而不是静默跳过字符返回乱码。
**依据**：🟢 `java-api.js` `b64normalize` + `looksLikeText`；🟡 build165 真机日志。
**现状**：✅ build165 修。
⚠️ **静默跳过是最坏的失败方式**：看着像「服务器返回了坏数据」，沙盒（载荷干净）还正常。

---

## 11. S-DAT `data:` 伪 URL

### S-DAT-01 绝不能真去 fetch
**规范**：`data:;base64,<载荷>` 这种伪 URL **不得**交给原生网络层真发请求。
**依据**：🟢 `engine.js` `fetchPage` + `java-api.js` `rawRequest` 都有拦截；🟡 build162/207。
**现状**：✅ build207 修。
⚠️ 原生 `URLSession` 会去解 data: URL 的 base64 ⇒ 抛「illegal base64 data at input byte 9」。

### S-DAT-02 载荷当**页面内容**
**规范**：伪 URL 的载荷 = 页面内容，直接返回给规则。
**依据**：🟢 `fetchPage`。
**现状**：✅。

### S-DAT-03 剥掉 `,{json}` 选项后缀
**规范**：`data:;base64,<载荷>,{"type":"qingtian2"}` 的尾部选项要去掉。
**依据**：🟡 build146 第 6 项。
**现状**：✅。

### S-DAT-04 载荷要按 **UTF-8** 解
**规范**：base64 解出来的字节要按 UTF-8 解释。
**依据**：🟢 build210（`atob` 返回 Latin-1 ⇒「小说」变「å°è¯´」）。
**现状**：✅ build210 修。

### S-DAT-05 宿主要把书的原始字段补进载荷
**规范**：站方生成的 `data:` 载荷里若缺 `book_id` 等字段，宿主应把**书籍对象的原始字段**
补进去（并重新编码）。
**依据**：🟢 build212 `dataUrlContent(u, book)`。
**现状**：✅ build212 修。

---

## 12. S-TPL 模板插值

### S-TPL-01 `{{}}` 插值
**规范**：`{{表达式}}` 替换为求值结果。支持 `{{baseUrl}}`、`{{$.字段}}`（对上一条结果做 JSONPath）、
`{{java.md5Encode(k)}}` 等 JS 表达式。
**依据**：🟢 `interpolate`（:1386）；🟡 Legado `containsMakeUpTemplate()`。
**现状**：✅。

### S-TPL-02 整条规则就是一个 `{{占位符}}` ⇒ 结果就是这个值
**规范**：插值后规则整体是单个 `{{…}}` ⇒ 直接返回该值，**不再往下走选择器**。
**依据**：🟢 `rule-analyzer.js:830-833`。
**现状**：✅。
⚠️ 不这么判的话 `{{source.u}}` 展开成 `"S"` 会被当 `<s>` 标签选择器
（`s`/`b`/`i`/`p` 本来都是合法 HTML 标签名）。

### S-TPL-03 插值产出的值**不得**再当选择器
**规范**：只要插值真的发生过，插值结果就是**值**——即使含换行 / `>` / `.`。
**依据**：🟢 `rule-analyzer.js:840-843` + `headIsValue`（:873）。
**现状**：✅。
⚠️ 症状：`{{$.introduction}}##(^|[。！？]+…)##$1<br>` 得到**空简介**（简介被当 CSS 查了）。

### S-TPL-04 `@js:` 规则里**不做** `{{}}` 插值
**规范**：规则是 `@js:` 形态时，**不要**对 JS 代码做 `{{}}` 插值。
**依据**：🟢 build202。
**现状**：✅ build202 修。

### S-TPL-05 裸词兜底不得被当字面量返回
**规范**：像 `a@text || text` 这种兜底里的裸词 `text`/`href`，**不能**当字面量返回。
**依据**：🟢 `rule-analyzer.js:840`（要求插值真的发生过）；🟡 肉文屋（目录里出现一排字面写着 "text" 的章节）。
**现状**：✅。

---

## 13. S-FBK 兜底链

### S-FBK-01 `||` 择一
**规范**：`a || b || c` ⇒ 逐个求值，**第一个非空**的结果胜出。
**依据**：🟡 Legado 语义。
**现状**：✅。

### S-FBK-02 `&&` 串接
**规范**：`a && b` ⇒ 各段结果**依次求值并拼接**。
**依据**：🟡 Legado 语义。
**现状**：✅。

### S-FBK-03 `,` 分隔的**完整规则** ⇒ 择一
**规范**：`a@x, b@x` ⇒ 逗号把规则切成多条**完整规则** ⇒ 逐个尝试，**第一个非空**胜出。
**依据**：🟡 Legado 语义。
**现状**：✅。

⚠️ **别跟 §S-FBK-05 混**：逗号有两种含义，靠「切开后每段是否都带 `@`」区分。

### S-FBK-04 ⭐ 换行多规则 ⇒ **结果合并**
**规范**：`a@x\nb@y` ⇒ **每一行各自求值，结果合并**成一个列表。
**依据**：🟡 站方多规则就是**换行**写的（不是逗号）。
**现状**：✅。

⚠️ **轻阅的债**：实测轻阅 `getElements("a@text\nb@text")` **只返回第一行**
⇒ 站方多写一行就少一半内容。
⇒ 字符串出口（字段规则）取**第一个非空**；列表出口（`getElements`）**合并**。

### S-FBK-05 ⭐ 头段逗号 = **CSS 选择器并集**（不是兜底链）
**规范**：`tag.h1, tag.h2` / `.catalog-section-title,.article-title a`
⇒ 逗号在**头段**（`@` 之前）⇒ 就是 **CSS 并集** ⇒ 原样交给 CSS 引擎。
**依据**：🟢 真书源逐字（书源「过期杂志」`ruleToc.chapterList`）。
**现状**：✅。

⭐ **这条是踩过坑才定下来的**：曾经把逗号当兜底链拆开
⇒ `.catalog-section-title,.article-title a` 第一段命中就停
⇒ **10 个卷标题在、16 个章节全丢** ⇒ 现象是「目录只有卷标题、没有章节」。
⇒ 真书源里 `.maglistbox` 在该页根本不存在 ⇒ `||` 后半段永远用不上
⇒ **两套选择器要一起命中的写法，只有 CSS 并集能表达**。

### S-JSON-08 ⭐ 过滤表达式 `[?(…)]`（栖阅 Sextant 风格）
**规范**：`$.data.state[?(@.dataName == 'x')].items[*]` ⇒ 过滤**数组元素**。
**依据**：🟢 栖阅用 Sextant（MIT）做过滤；**Legado 安卓端没有这层** ⇒ 两端行为差异的根源。
**现状**：✅（自研实现，见 `Sources/LegadoCore/Evaluator/JSONFilter.swift`）。

⭐ **过滤作用在「数组的元素」上**，不是数组本身 —— 否则 `@.x` 永远取不到。
⭐ 严格相等 `===` **类型也必须相同**（`1 !== '1'`）⇒ 数字/字符串别混。
⭐ `=~` 的语义是「**值 =~ 模式**」⇒ 模式在左或右都行（Sextant 源码两个分支都判）。
⭐ 运算符：`==` `!=` `===` `!==` `<` `<=` `>` `>=` `=~` `in` `nin` `subsetof` `anyof` `noneof` `exists` `&&` `||` `!`
⚠️ **单词运算符大小写不敏感**（Sextant 源码用 `uppercase()` 比对）。

### S-CMP-06 ⭐ 「路径 + 尾部 `<js>` 块」复合形态
**规范**：`$.data.x<js>…</js>` ⇒ 先按路径取值 ⇒ 结果作为 `result` 喂给 JS。
**依据**：🟢 125 源实测（4 处；`$.uptime<js>java.getString(…)</js>` 等）。
**现状**：✅（**解析层**已支持；**求值**要等 JS 后端）。

⚠️ 以前这里只认 `@js:` 后缀 ⇒ 这种规则被当**整串 JSONPath** ⇒ 解析失败
⇒ 体检报「JSONPath 语法不支持」⇒ **误判成语法问题**（其实是形态不支持）。

### S-VAL-01 ⭐ 整条规则 = **取值模式** ⇒ 取当前节点的这个值
**规范**：`text` / `href` / `html` / `ownText` …（**整条规则就是它**）
⇒ 语义是「取**基准节点**的这个值」，**不是**去查同名的 CSS 标签。
**依据**：🟢 真书源逐字（`"chapterName": "text"` / `"chapterUrl": "href"`）。
**现状**：✅。

⚠️ **与 `text.x` 不是一回事**：
- `text.x` ⇒ **筛选**（找文本**完全等于** x 的元素）
- `text`   ⇒ **取值**（取当前节点的文本）

⚠️ 以前这类规则被当 CSS 标签名查（`select("text")`）⇒ **永远查不到**
⇒ 现象是「目录有章节、但章名和章地址全是空」。

### S-VAL-02 尾部 `##正则##` ⇒ **删除 / 替换**（不是「纯提取」）
**规范**：
- `a@text##广告词` ⇒ **删除**匹配部分
- `a@text##广告词##替换串` ⇒ 替换
**依据**：🟢 真书源逐字（`ruleContent.content = "tag.p@html##我爱读者校园网"`）。
**现状**：✅。

⚠️ **「纯提取」是**整条规则**为 `##正则##` 时的语义**（取第 1 个捕获组）—— 跟尾部**不是一回事**。
⚠️ 以前尾部 spec 被拆坏 ⇒ 「无替换」时 pattern 变空 ⇒ **整条规则返回空**。

---

## 14. S-DIA 诊断不许说谎 ⭐

> 轻阅最贵的一课：**诊断误导比没有诊断更贵**。

### S-DIA-01 诊断必须走**真实路径**
**规范**：诊断用的求值路径，必须和真实执行路径**同一条**。
**依据**：🟢 `engine.js` `explainToc`（build164 改）；🟡 build160/162/164。
**现状**：✅ build164 修。
⚠️ 曾经诊断只按 HTML/CSS 路径数节点 ⇒ 对 **JSON 接口源**和**复合规则**必然报「命中 0 个」
⇒ 结论恒为「结构跟规则对不上」⇒ **所有人都以为规则写错了，其实规则是对的**。

### S-DIA-02 诊断的 ctx 必须带 `book`
**规范**：目录/详情诊断的上下文**必须**带 `book`。
**依据**：🟢 build164（`explainToc` ctx 补 `book`）。
**现状**：✅。
⚠️ 不带 book ⇒ 站方 JS 第一句 `book.getVariable('custom')` 就抛 ⇒ 永远 0 命中。

### S-DIA-03 诊断不许真去 fetch `data:` 伪 URL
**规范**：诊断请求必须走 `fetchPage`（和真实路径一致），**不许**走 `rawRequest`。
**依据**：🟢 build162。
**现状**：✅。
⚠️ 走 `rawRequest` ⇒ 原生去解 data: URL 的 base64 ⇒ 状态码 0 / 响应 21 字节 ⇒ **全是废数据**。

### S-DIA-04 失败不许静默吞成空串
**规范**：请求失败 / 异常状态 / 空响应，都要**显式打日志**。
**依据**：🟢 build165（`[ajax失败]` / `[ajax异常状态]` / `[ajax空响应]`）。
**现状**：✅ build165 修。
⚠️ 静默吞成空串 ⇒ 站方 `JSON.parse('')` ⇒ 「Unable to parse JSON string」⇒ 天书错。

### S-DIA-05 规则报错要带**上下文**
**规范**：规则报错日志要附「最后响应（URL / 状态 / 开头）」+「喂给规则的原文前 200 字」。
**依据**：🟢 `lastAjaxNote()`（:962）+ `baseNote()`（:981）。
**现状**：✅。
⚠️ 没有这两行，日志只有 `abstract.split` 这种天书，根本看不出服务器返回了啥。

### S-DIA-07 ⭐ **「真错误」必须与「规则没命中」区分开**
**规范**：
- **规则没命中** ⇒ 正常结果（兜底链里第一段没命中是常态）⇒ 诊断 failure = `.noMatch`
- **真错误** ⇒ 响应类型不对 / 后端没接 / 语法不支持 / 宿主对象没传 ⇒ failure 标 `isHardFailure`
- ⇒ 宿主的 UI **必须能显示不同的提示**（不能都显示「没找到」）

**依据**：🟢 轻阅的病根就是「静默失效」——界面只显示「0 结果」，
用户和开发者都以为规则写错了，实际可能是「响应类型不对」或「后端没接」。
**依据**：🟡 栖阅的诊断面板按**步骤事件链**分级（`consumedChars=0` / `parseFailExceptions`），
⇒ 分级是刚需，不是锦上添花。
**现状**：✅ 自研已实现（`EngineDiagnostic.Failure.isHardFailure` + `DiagnosisConclusion` 六态）。
⚠️ **实现过程中我自己踩过**：一开始 `EngineDiagnostic` 定义了却**一次都没被调用**，
求值器 19 处 `return .void` 全是静默 ⇒ **规格写了但实现没做**（2026-10-23 自查发现）。

### S-DIA-06 诊断的「命中元素数」对 `@js:` 规则**无意义**
**规范**：诊断面板对 `@js:` / 复合规则**不许**报「命中元素数 0」。
**依据**：🟡 build205 期间踩过（`resolveNodes` 对 `@js:` 恒为 0）。
**现状**：⚠️ **未完全覆盖**——`explain` 路径对 JS 规则应报「JS 路径命中 N 条」。
（`explainToc` 已在 build164 改对；通用 `explain` 待确认。）

---

## 15. S-JS 宿主能力桥

### S-JS-01 `java.ajax` 是**同步**的
**规范**：`java.ajax(url[, options])` 同步返回响应正文。
**依据**：🟡 Legado 语义（站方按同步写）。
**现状**：✅（靠「两遍跑」机制实现——见 S-JS-02）。

### S-JS-02 两遍跑：缓存**优先**，再录制
**规范**：`java.ajax` 查缓存**在前**，录制备用。
**依据**：🟡 build148（缓存顺序反了 ⇒ 缓存永远命中不了 ⇒ 请求反复发、浏览器反复弹、拿到的永远是空值）。
**现状**：✅ build148 修。

### S-JS-03 两遍跑要**循环**，不是固定两遍
**规范**：交接链是「开浏览器 → 用户登 → 抠 token → 带 token 交接」，
第一遍页面是空的 ⇒ **交接 URL 本身就是错的** ⇒ 要循环到「不再有新调用」为止。
**必须**有轮数上限（5）+ 缓存上限（40），防随机码 URL 死循环卡死 App。
**依据**：🟡 build151。
**现状**：✅ build151 修。

### S-JS-04 抓取要**按代码顺序**，不能并行
**规范**：站方交接链必须顺序抓（浏览器在前 → 等用户登完 → 再发交接）。
**依据**：🟡 build151（并行 ⇒ 交接在用户没登完时发出 ⇒ 返回空 ⇒ "Unexpected EOF"）。
**现状**：✅ build151 修。

### S-JS-05 对象字面量里同名成员**只许定义一次**
**规范**：同一个 JS 对象字面量里，同名成员只许出现一次（后定义的会**静默覆盖**前面的）。
**依据**：🟡 build156（`startBrowserAwait` 定义两遍 ⇒ 第二份绕开两遍跑 ⇒ 原生没有该 op ⇒ 静默失败 ⇒ 浏览器根本不弹；站方 15 处用它全废）。
**现状**：✅ build156 修（门禁断言 `grep -c` == 1）。

### S-JS-06 引擎脚本**严格模式** ⇒ 未声明变量赋值会抛
**规范**：引擎脚本在严格模式下运行 ⇒ 未声明变量赋值 = `ReferenceError` ⇒ **每个 op 都失败**。
**依据**：🟡 build159（`mergedHosts` 漏 `var` ⇒ 整个引擎瘫掉；且站方自己 catch 住 ⇒ 静默）。
**现状**：✅ build159 修（加 `var`）+ 新增 eslint `no-undef` 门禁。
⚠️ **jsdom/node 的 vm 复现不出**（Proxy 抹平了严格模式）⇒ 只能静态查。

### S-JS-07 jsLib 里的自由变量要能解析到全局
**规范**：站方 jsLib 是**间接 eval** ⇒ 它的 `var`/`function` 落**全局作用域** ⇒
函数体里的自由变量 `source`/`result`/`book` 解析到**全局对象**。
⇒ 引擎必须把当前 scope 的 `source`/`result`/`book` **同步到全局**。
**依据**：🟡 build146（站方 `setArguments`/`login` 就是 `const { source } = this;` ⇒ 全局对象上必须同时有 source 和 result）。
**现状**：✅ build146 修。

### S-JS-08 `loginUrl` 依赖 `jsLib` ⇒ 必须**先加载 jsLib**
**规范**：加载 `loginUrl` 之前必须先加载 `jsLib`（站方 loginUrl 依赖 jsLib 里的 `host`）。
**依据**：🟡 聚合源实测。
**现状**：✅。

### S-JS-09 登录信息/书籍变量按**源**隔离
**规范**：登录信息、书籍变量按 `bookSourceUrl` 存。
**依据**：🟢 `Core/SourceVariables.swift`。
**现状**：✅。

### S-JS-10 `source.getVariable/setVariable` 语义 = **整份 vars 的某一项**
**规范**：`get` 取不到该项时返回**空串**（不是整份 JSON）；`put` 改一项。
**依据**：🟡 聚合源（🍒NovelHub）实测：`String(source.get("nhAuthed") || "")` 比对哈希 ⇒ 拿到整份 JSON 就对不上。
**现状**：✅ build204 修。

---

## 16. S-URL URL 构造

### S-URL-01 query 编码对**所有方法**做
**规范**：`analyzeUrl` 生成的 query，**GET / POST 都要**重新编码。
**依据**：🟢 栖阅 `smartPercentEncode`；🟡 build166（只给 GET 编码 ⇒ POST 的裸中文 + 裸 JSON
⇒ iOS `URL(string:)` 返回 nil ⇒ 请求**根本没发出去**）。
**现状**：✅ build166 修（字符集与栖阅**逐字一致**）。

### S-URL-02 对象 body → JSON 序列化
**规范**：body 是对象 ⇒ `application/json` + JSON 序列化（不是 `String(obj)`）。
**依据**：🟡 栖阅 `parseJsonConfig`；🟡 build167。
**现状**：✅ build167 修。

### S-URL-03 `+` 必须编码成 `%2B`
**规范**：query 里的 `+` ⇒ `%2B`，`/` ⇒ `%2F`。
**依据**：🟡 build168（base64 载荷进 query，`+` 原样留着 ⇒ 服务器 form 解码成空格 ⇒ book_id 被损坏
⇒ 「有的书能开、有的书开不了」）。
**现状**：✅ build168 修。

### S-URL-04 URL 选项 `,{json}`
**规范**：规则产出的 URL 尾部 `,{json}` = 本次请求的 method/body/headers 选项。
**依据**：🟢 栖阅 `parseHeaders` / `parseJsonConfig`；🟡 build214 第三项。
**现状**：✅ build214 修。

---

## 17. S-FLT 过滤表达式（Sextant）

> 完整语法见 `栖阅-轻阅-引擎对账.md` §3.5（从 Sextant 源码读出来的，源码级事实）。

### S-FLT-01 运算符全集
**规范**：支持 `== != === !== < <= > >= =~ IN NIN SUBSETOF ANYOF NONEOF CONTAINS ALL EXISTS TYPE SIZE EMPTY`。
**依据**：🟢 Sextant `RelationalOperator.swift` + `Evaluator.swift`。
**现状**：✅ build170（`sextant-filter.js`）。

### S-FLT-02 单词运算符**大小写不敏感**
**规范**：`in` / `contains` / `size` / `empty` 等单词运算符大小写不敏感。
**依据**：🟢 Sextant `RelationalOperator.init?(hitch:)` 用 `hitch.uppercase()` 匹配。
**现状**：✅ build170。

### S-FLT-03 解析不了要**回落**老实现
**规范**：新求值器解析不了表达式时，**回落**老实现，**不许误杀书源**。
**依据**：🟢 build170（`jsonpath.js` 的 `case 'filter'` 优先新求值器，解析不了回落）。
**现状**：✅ build170。

### S-FLT-04 数组字面量与集合运算符是**已知坏点**
**规范**：Sextant 的**路径切分**遇到 filter 里的嵌套方括号会切坏 ⇒
① filter 里写数组字面量 `['S','M']` 不行；② 集合运算符（`IN`/`SUBSETOF`…）因为右值必须是数组而数组字面量又坏 ⇒ 不行。
⇒ **栖阅的 filter 实际只能做标量比较。**
**依据**：🟢 栖阅 Swift 侧实测返回 `[]`；🟡 轻阅**一样坏**（两边行为一致，不是轻阅没对齐）。
**现状**：⚠️ **两边一致地坏**。想强于栖阅，要改 `jsonpath.js` 的路径切分（方括号改括号配对）。

---

## 17.5 S-DOM DOM 层语义（Phase 2 新增）

> 实现：`Sources/LegadoCore/DOM/`（SwiftSoup 后端 + 协议化）
> 对拍：`conformance/fixtures/semantics-cases.json` 的 `domSelect` 用例（12 条，真 HTML + 125 源真规则）

### S-DOM-01 头段与链段的翻译规则**不同**
**规范**：
- **头段**（第一个 `@` 之前）走 `prefixToCss` 语义 —— **没有 `kw.` 前缀就原样当纯 CSS**
- **链段**（`@` 后面）走 KW 分类 —— 裸标签名当**子选择器**（§S-SEL-06）
**依据**：🟢 轻阅 `jsoup-compat.js` 的 `parseChain`（头段 `prefixToCss(head)`，链段 KW 分类）。
**现状**：✅ 自研已按此实现。
⚠️ **我早先把两者混成一个分类器** ⇒ 纯 CSS 的 `dl.B dd` 被误判成属性名 ⇒ **已修**。

### S-DOM-02 真实标签当前缀时，值整体当**类名**
**规范**：头段里 `ul.MLlist li` ⇒ 翻译成 `ul.MLlist li`（标签 `ul` + 类名 `MLlist li`）
⇒ 标准的**后代选择器**语义保住。
**依据**：🟢 轻阅 `prefixToCss` 的 `marks[i].raw` 分支。
**现状**：✅ 两边一致（`head-08` 用例）。

### S-DOM-03 空 CSS（纯后置伪类）的候选集 = **root + 所有后代**
**规范**：`text.查看目录` 这种「无 CSS、只有后置过滤」的规则 ⇒ 候选是**整个文档的所有元素**，
不是只有 root。
**依据**：🟢 轻阅 `queryOne` 的 `!clean || clean === '*'` 分支。
**现状**：✅ 自研已按此实现。
⚠️ **我早先只返回 `[root]` ⇒ 后置过滤被跳过** ⇒ 命中的是 document 自己（文本是整页）⇒ **已修**。

### S-DOM-04 选择器查询**含元素自身**
**规范**：`element.select("div.c")` 在 `div.c` 内部查询时，**要能命中它自己**（Jsoup 语义）。
**依据**：🟢 轻阅 `jsoup-compat.js` 的注释明确写了这点（Jsoup 的 `select()` 含自身）。
**现状**：✅ SwiftSoup **原生就是这个语义**（实测 `div.c` 内查 `div.c` = 1）⇒ 零适配成本。

### S-DOM-05 SwiftSoup 缺 `:textEquals` ⇒ 自己用后置过滤补
**规范**：`:textEquals` / `:containsOwn` 等 SwiftSoup 不支持的伪类 ⇒ **查完再过滤**。
**依据**：🟢 实测 SwiftSoup 支持 `:contains` `:containsOwn` `:matches` `:matchesOwn` `:not` `:nth-child` `+` `~` `[attr^=]`；
**不支持** `:textEquals` `:hasText` `:containsWholeText` `:matchesWholeText`。
**现状**：✅ `PseudoFilter` 实现。
⚠️ **对拍时要比「最终行为」（节点数/文本），不要比中间 CSS 串** —— 轻阅把伪类留在串里再摘，
本实现直接摘 ⇒ 字符串不同但行为等价 ⇒ 用 `SelectorSpec.cssLike` 归一化。

### S-DOM-06 选 DOM 实现 = **SwiftSoup**
**规范**：HTML 解析 + CSS 选择器用 SwiftSoup；XPath 另做子集。
**依据**：🟢 SwiftSoup 的 HTML5 容错 + Jsoup 兼容的选择器语义（自身包含、并列 class、`:contains`）。
**现状**：✅ 已接入（`Package.swift` 的 SPM 依赖）。
⚠️ **SPM 拉依赖会被沙盒的 CA 问题卡住** ⇒ 需 `git config --global http.sslCAInfo <ca>` + `http.version HTTP/1.1`。

### S-DOM-07 ⭐ XPath 子集（自研，2026-10-23）
**规范**：宿主必须支持 Legado 的 `@XPath:` / 裸 `/` 开头规则。
**依据**：🟡 125 源实测 **28 条** XPath 用法，语法种类就那么几样 ⇒ 子集照真实需求定。

| 语法 | 例子（**都是 125 源的真规则**） | 语义 |
|---|---|---|
| `//tag` / `//*` | `//ul[@class='mulu_list']/li` | 所有后代里的元素 |
| `/tag` | `/html/body` | 直接子元素 |
| `tag[@attr='v']` | `//p[@class='mb-1 text-muted']` | 属性**完全相等**（⭐ 标准 XPath） |
| `tag[contains(@attr,'v')]` | `//ul[contains(@class,'vodlist')]/li` | 属性包含 |
| `tag[n]` | `//tr[1]` | 第 n 个（**1-based**） |
| `tag[p1][p2]` | `//div[@class='x'][@id='y']` | 多个谓词（AND） |
| `/text()` | `//a/text()` | **直接子文本节点**（不是完整文本） |
| `/@attr` | `//a/@href` | 属性值 |

**现状**：✅ 自研已实现（`Sources/LegadoCore/DOM/XPathEngine.swift`），
与轻阅的 `document.evaluate`（**标准 XPath**）**逐字一致**（6 条对拍用例全过）。

⚠️ **三个容易搞错的点**：
1. **`@class='a b'` 是完全相等** ⇒ ⚠️ **HTML 的 class 属性值本来就是空格分隔的整串**
   （`<p class="a b">` 的属性值就是 "a b"）⇒ **匹配得上**（我一开始以为匹配不上，**错了**）
   ⇒ 站方要「按 class 包含」才写 `contains(@class,'a')`
2. **`text()` 取的是直接子文本节点**，不是元素的完整文本
   ⇒ `<a><span>x</span></a>` 的 `text()` 是**空串**
3. **位置索引是 1-based**（XPath 语义）⇒ `tr[1]` 是**第一个**（不是第 0 个）

⚠️ **`//xpath:` 前缀不剥**（那是 XPath 1.0 的命名空间语法，jsoup / document.evaluate 都不认）
⇒ 只剥 `xpath:`（跟轻阅 `evalXPath` 的 `replace(/^xpath:/i,'')` 一致）

⚠️ **轻阅的 `jsoup-compat.js` 完全没有 XPath** ⇒ `QR.dom.selectAll(doc, xpathRule)`
会把 XPath 规则**当 CSS 处理** ⇒ 结果乱。**只有 `QR.rule.evalOne` 的 XPath 分支是对的**。
⇒ ⇒ **对拍 XPath 必须走完整求值路径，不能只测选择器** ⭐（这个坑我踩了一次）

## 17.8 S-EVAL 求值器语义（Phase 2b 新增）

> 实现：`Sources/LegadoCore/Evaluator/`
> 对拍：fixture 的 `evalOne` / `getElements` 用例（41 条，真规则 + 真基准）

### S-EVAL-01 求值顺序 = `@put/@get` → 插值 → 解析 → 求值
**规范**：
① `@put:` / `@get:` 内嵌处理（会改源级变量）
② **模板插值**（⚠️ **JS 模式不插值**，§S-TPL-04）
③ 解析成 AST
④ 按 AST 求值
**依据**：🟢 轻阅 `evalOne` 的顺序。
**现状**：✅ 自研已按此实现。

### S-EVAL-02 ⭐ 整条规则是一个 `{{占位符}}` ⇒ **直接返回插值结果**
**规范**：判的是**原规则**（插值前），不是插值后的规则。⇒ 插值结果**不再往下走选择器**。
**依据**：🟢 轻阅 `evalOne` 的 `rule !== rawRule && /^\s*\{\{[\s\S]*\}\}\s*$/.test(rawRule)`。
**现状**：✅ 自研已按此实现。
⚠️ **我早先漏了这条** ⇒ 插值后变成一个裸值 ⇒ 被当选择器去查 ⇒ 结果空。

### S-EVAL-03 ⭐ 规则本身是**字面 URL** ⇒ 原样返回
**规范**：`https://x/read/@get:{xid}/{{$.num}}` 插值后是纯 URL ⇒ **当值返回**，不当选择器查。
**依据**：🟢 轻阅 build214 加的（实测 125 源里 4 个源这么写）。
**现状**：✅ 自研已按此实现。

### S-EVAL-04 兜底链的判空：`||` 要跳过**空字符串**
**规范**：`a || b` 逐个求值，**第一个非空**胜出。⇒ 空字符串算「空」。
**依据**：🟡 Legado 语义；🟢 轻阅 `tryOr` 的判空口径。
**现状**：✅ 自研已按此实现（`.json(.string(""))` 算空）。
⚠️ **我早先把 JSON 空字符串当非空** ⇒ `result.n || result.m` 里 `n` 为空时**不继续** ⇒ 拿到空串。

### S-EVAL-05 `&&` 串接 = 依次求值**并拼接**
**规范**：`a && b` ⇒ 两段结果拼接（不是「第一个非空」）。
**依据**：🟡 Legado 语义。
**现状**：✅ 自研已按此实现。

### S-EVAL-06 正则纯提取 = 取**第 1 个捕获组**
**规范**：`##pat##`（无替换）⇒ 取第 1 捕获组，没有则取整段。
**依据**：🟢 轻阅 `applyRegex`（`m.length > 1 ? m[1] : m[0]`）。
**现状**：✅ 自研已按此实现。

### S-EVAL-07 正则替换的 `$1..$n` 取**原文本**的捕获组
**规范**：替换串里的 `$1` ⇒ 原文本的第 1 个捕获组。
**依据**：🟡 正则语义。
**现状**：✅ 自研已按此实现。
⚠️ **我早先错用「matched（匹配片段）」的 range** ⇒ 捕获组范围越界 ⇒ **运行时崩溃**。
⚠️ 同理，**不能用 `replacingOccurrences(of: matched, ...)`** —— `of:` 是**正则**，
匹配片段里含 `$` `(` `*` 等元字符 ⇒ 会匹配到错误范围甚至越界。

### S-EVAL-08 ⭐ **头段**也可以带索引
**规范**：`tag.li.0`（整条没有 `@`）⇒ 头段 = "tag.li"，索引 = 0。
**依据**：🟢 轻阅 `prefixToCss` 的 `__IDX__N__` 机制 + `idxM = /^(.*?)(?:#|\.)(-?\d+)$/`。
**现状**：✅ 自研已按此实现（`RuleNode.chain(head:headIndex:steps:)`）。
⚠️ **我早先只给链段做了索引，头段漏了** ⇒ `tag.li.0` 查不到。

### S-EVAL-09 值系统两种出口
**规范**：
- **字段规则**（name/author/…）⇒ 出口统一是 `String`
- **列表规则**（bookList/chapterList）⇒ 出口统一是 `[RuleValue]`
- **JSON 对象** ⇒ `.json(JSONValue)`，**不得**被隐式 stringify（§S-JSON-02）
**依据**：🟢 轻阅 build161/213 反复修的就是这件事（对象被 flatten 成字符串 ⇒ 章节全毁）。
**现状**：✅ 自研已按此实现（`RuleValue.text` / `RuleValue.items`）。

### S-EVAL-09b ⭐ 基准类型不对 ⇒ **真错误**，不是「没命中」
**规范**：规则是 JSONPath 但响应**不是 JSON** ⇒ 报「基准类型不符」，**不许**静默「没命中」。
**依据**：🟡 真实场景（站方规则写 `$.title`，接口返回的是 HTML 错误页）。
**现状**：✅ 自研已实现（`baseJSON` 用 `ctx.isJSON` 判定，不是盲猜）。
⚠️ 我早先写成 `JSONValue.from(raw)` ⇒ HTML 被当字符串 ⇒ 查不到 ⇒ **静默空**。

### S-EVAL-11 ⭐ 规则 AST **可缓存**
**规范**：规则串 → AST 的解析**只做一次**，同一规则重复求值时复用 AST。
**依据**：🟢 同一个 `bookList` 匹配几百项 ⇒ 同一批字段规则要跑几百遍 ⇒ 解析是纯浪费。
**现状**：✅ 自研已实现（`RuleCache` + `RuleParser(cache:)`）。

⭐ **两条纪律**：
1. **只缓存「整条规则」的 AST**，**递归切分出来的子段不进缓存**
   ⇒ 否则缓存里全是碎片，命中率低且 key 爆炸
2. **缓存不能改变行为** ⇒ 命中缓存的 AST 必须与现算的**逐字相同**
   ⇒ 有门禁专门断言（`testCachedASTMatchesFreshAST`）

⚠️ **缓存键必须含 `isJSON`**（它影响模式判定，§S-CLS-08）⇒ 同一规则在 JSON / HTML 响应下
是两个不同的键。

⚠️ **换书源时该清缓存**（不同源的规则可能同名但含义不同）。

**实测收益**（`swift run conformance --bench`，6 条规则 × 20000 轮）：
`无缓存 10.95s / 有缓存 0.13s` ⇒ **加速 ≈ 85 倍**，命中率 100%
（⚠️ 这个数字**偏保守**：两边都付了同样的 AST 描述开销）

### S-EVAL-12 ⭐ 纯副作用规则（`@put:` / `@get:`）**不产出值，也不是错误**
**规范**：整条规则只有 `@put:{k:v}` / `@get:{k}` ⇒ 它**只做副作用**（读写变量），本来就不产出内容。
**依据**：🟢 125 源实测（`ruleExplore.kind = "@put:{bid:$.bookId}"`）。
**现状**：✅。

⚠️ 以前这里 parse 成空 ⇒ 诊断报「规则解析不出内容」⇒ **诊断在说谎**（§S-DIA）
⇒ 现在诊断明确标「副作用规则（不产出值）」，**不算真错误**、也不算「没命中」。

### S-EVAL-10 JS 规则的求值
**规范**：`@js:` / `<js>` ⇒ 交给 JS 后端执行；`result` 按基准分层（§S-RES）。
**依据**：🟡 Legado 语义。
**现状**：⏳ **未实现**（Phase 3 接 JSC）⇒ fixture 里标 `requires: "js"` ⇒ **两边都跳过**，不算差异。
⚠️ **未实现的规则必须明确跳过，不许伪装成「没命中」**。

## 17.9 S-HOST 宿主适配（Phase 2e 新增）

> 实现：`Sources/LegadoCore/Host/`
> 对拍：fixture 的 `urlRule` 用例（12 条）+ `reference/swift/AnalyzeUrl.swift`（轻阅的参考实现，**只读**）

### S-HOST-01 ⭐ URL 规则 = 请求构造的语义核心
**规范**：规则里的 URL 决定用什么 method、带什么 headers、body 是什么、query 怎么编码。
**依据**：🟢 栖阅的 `AnalyzeUrl` 是**原生 Swift**；🟡 轻阅原来放在 JS 里 ⇒ 沙盒（Node fetch）和真机（`URL(string:)`）
用了**两套不同的 URL 实现** ⇒ 已经栽了两次（build166 / build167）。
**现状**：✅ 自研已实现（`URLBuilder`），**与参考实现逐字一致**（12 条对拍全过，0 DIVERGE）。

⭐ **四条最容易错的语义**：
| # | 规则 | 栽过的坑 |
|---|---|---|
| 1 | **query 重新编码对【所有方法】做** | 只给 GET 编码 ⇒ POST 的裸中文 + 裸 JSON ⇒ `URL(string:)` 判非法 ⇒ **请求压根没发出去** |
| 2 | **`+` → `%2B`** | 留着 `+` ⇒ 服务器 form 解码成**空格** ⇒ base64 `book_id` 被损坏 ⇒ **有的书能开、有的书开不了** |
| 3 | **`data:` / `blob:` 原样返回** | 百分号编码会改掉 base64 载荷里的 `+` `/` ⇒ 站方解不出 JSON |
| 4 | **选项后缀从【左边】第一个逗号找** | 用 `lastIndex` ⇒ 对 `url,{"method":"POST","body":{...}}` 最后一个逗号在 `"POST",` 后面 ⇒ **选项拆不出来** ⇒ method/body 全丢 ⇒ 请求用 GET 发 |

⚠️ **「原样返回」的 scheme 必须是【白名单】**，不能是「所有自定义 scheme」
⇒ 我第一版写成「所有自定义 scheme」⇒ **`https:` 也被当成自定义** ⇒ 整个 URL 原样返回
⇒ query 里的裸中文不编码 ⇒ 请求发不出去 ⭐

⚠️ **绝对化 / 取目录要用 Foundation**（`URL(string:)` / `deletingLastPathComponent`），别手搓字符串拼接
⇒ 沙盒验的就是真机同一套 Foundation 行为。

### S-HOST-02 ⭐ Cookie 罐必须由宿主自己管
**规范**：
- **写了 `Domain`** ⇒ 匹配该域**及其所有子域**
- **没写 `Domain`** ⇒ **只匹配 host 完全相等**（不能给子域发，更不能给父域发）
- `Path` 前缀匹配
- `secure` cookie 只走 https
- **过期 cookie 要删掉**（不然登录态"看着还在、其实已失效"）
- 同名 + 同域 + 同路径 ⇒ 覆盖

**依据**：🟡 站方聚合源的 cookie 是**站方服务器认的**（如番茄的 `sessionid_ss`）⇒ 必须**同一个罐**跨请求保持。
**现状**：✅ 自研已实现（`CookieJar`）。

⚠️ **「没写 Domain」的判定我写错过**：早先写成 `host == url.host?.lowercased()`
⇒ **自己跟自己比，恒真** ⇒ 没写 Domain 的 cookie 会被发给**任何域** ⭐
⇒ 修法：Cookie 额外记 `host`（来源 host）⇒ 没写 Domain 时拿它做「完全相等」判定。

### S-HOST-03 HTTP 传输是**协议**，宿主注入
**规范**：核心层只依赖 `HTTPTransport` 协议 ⇒ **不依赖 URLSession**。
**依据**：⭐ 核心层要能在 **Linux 沙盒**里真编真跑 ⇒ URLSession 在 Linux 上行为与 Apple 有差异，
且同步封装麻烦 ⇒ 不适合放进核心层。
**现状**：✅ `HTTPTransport` 协议 + `HTTPRequest` / `HTTPResponse` / `PageFetcher`（规则 → 请求 → 响应一条龙）。

### S-HOST-04 `PageFetcher` 把「URL 规则」和「取页面」合成一步
**规范**：取页面 = URL 规则解析 + 带上 cookie + 发请求 + 收 cookie。
**依据**：🟢 这两件事本来就是**一件事**（URL 规则决定 request 怎么发）⇒ 不该拆在两个层里。
**现状**：✅ `PageFetcher.fetch(rule:baseUrl:timeout:)`。

## 17.95 S-PIPE 编排层语义（Phase 3 新增）

### S-PIPE-01 ⭐ **相对地址的基准 = 当前页的最终 URL**
**规范**：列表项里的相对 `bookUrl` / `chapterUrl` ⇒ 相对**它所在那一页的 URL** 绝对化。
**依据**：🟡 Legado 语义（`abs:href`）。
**现状**：✅。

⚠️ **基准搞错就整体歪一级**：详情页 URL 是 `…/2026/bkzs/202614/index.html`
⇒ 章节链接 `articles/x.html` ⇒ 绝对化后是 `…/2026/bkzs/202614/articles/x.html`；
若错用书源首页当基准 ⇒ `…/articles/x.html` ⇒ **404**。

### S-PIPE-02 ⭐ 字段规则在**条目节点内**相对求值
**规范**：`bookList` 命中的每个节点 ⇒ 字段规则（`name` / `author` / `bookUrl`…）在**该节点内部**求值。
**依据**：🟡 Legado 语义（`AnalyzeByJSoup.getElements` 用 `element.select(rule)`）。
**现状**：✅。

⭐ 靠「选择器查询**含元素自身**」一条语义同时覆盖两种站方写法：
- `name: "a@text"` 作用在 `div` 节点 ⇒ 命中**后代** `a`
- `chapterName: "text"` 作用在 `a` 节点 ⇒ 命中**自身**（§S-VAL-01）

### S-PIPE-03 ⭐ `tocUrl` 为空 ⇒ 目录规则在**详情页**上跑
**规范**：`ruleBookInfo.tocUrl` 为空 ⇒ 目录页 URL = `bookUrl`。
**依据**：🟡 Legado 语义。
**现状**：✅。

### S-PIPE-04 ⭐ 相对求值 ⇒ URL 属性**要绝对化**
**规范**：`href` / `src` 属于 URL 属性 ⇒ 取值时按当前页 URL 绝对化。
**依据**：🟡 Legado 语义（Jsoup `abs:href`）。
**现状**：✅。

### S-PIPE-05 ⭐ **空结果要抛错，不许静默返回空数组**
**规范**：列表规则没命中 ⇒ 抛 `SourceError.emptyResult(字段名)`。
**依据**：🟢 本项目主张（§S-DIA「不许静默失败」）。
**现状**：✅。

### S-PIPE-06 ⭐ 书源模型**必须容错解码**
**规范**：缺字段 ⇒ nil；字段类型不对 ⇒ 当没这个字段；**绝不让整个源解不出来**。
**依据**：🟢 轻阅 build215 真机事故（`KindsDTO` 少一个 `group` ⇒ 整个 op 结果全废）。
**现状**：✅。

⚠️ Swift 的**属性默认值只对「构造」生效，对「解码」不生效** ⇒ 必须显式 `decodeIfPresent`。

## 18. 尚未覆盖 / 已知缺口

| # | 缺口 | 状态 | 备注 |
|---|---|---|---|
| 0 | **链段里的裸标签名被当属性名**（S-SEL-06） | ⛔ **债（重量级）** | **125 源里 279 处、60 个源（48%）**。链断 ⇒ 取到父元素整体 ⇒ 「目录只有 1 章」「搜索只出 1 本」「发现页出不来」「封面空白」。一改就影响 60 个源，**必须配活体回归**。 |
| 0a | ~~`!N` 排除在链中段不生效~~ | ✅ **撤回** | 2026-10-23 逐位置实测：排除语法**本身没问题**。不生效的是「裸标签名」那一段 ⇒ 属 S-SEL-06 的连带。 |
| 0b | **`flatten()` 吃掉 `{title,url}` 对象的标题**（S-JSON-06） | ⛔ **债** | `dom.textOf(字符串)` 返回 `''` ⇒ 标题整段没了。列表路径不受影响 ⇒ 症状隐蔽。 |
| 1 | **JS 全局态治理**（`restoreMutatedBaseGlobals` / `purgeUnexpectedGlobals`） | ❌ **轻阅没有** | 防**书源 A 的 jsLib 污染书源 B**。轻阅共用一个 WebView ⇒ **必现**。栖阅有。 |
| 2 | `@webjs:` 模式（`RuleMode.webJs`） | ❌ 没有 | WebView 里跑 JS |
| 3 | 真 XPath（libxml2 + `Kanna`） | ❌ 没有 | 轻阅是 jsdom/WKWebView 的 `document.evaluate` |
| 4 | 自研 JSONPath（`JsonElement` + `PathToken`） | ❌ 没有 | 轻阅是自写 `jsonpath.js` |
| 5 | `@http:` 规则前缀 | ❌ 没有 | 栖阅有 |
| 6 | `multipart` body（`buildMultipartBod`） | ❌ 没有 | 少用 |
| 7 | JS 中断看门狗（`JSContextInterruptWatchdog`） | ❌ 没有 | 轻阅靠 op 超时 360s + 重置引擎 |
| 8 | `isValidJsCode()` 语法预检 | ❌ 没有 | 低优先 |
| 9 | S-DIA-06（`@js:` 规则的「命中元素数」无意义） | ⚠️ 部分 | `explainToc` 已改；通用 `explain` 待确认 |
| 10 | 栖阅原生 Swift 规则引擎 | ❌ 抄不了 | 逆向材料只有符号名 + 字面量，**没有实现** ⇒ 只能从零重写 |
| 11 | **JS 后端（JSC）** | ❌ 没有 | Phase 3 的编排层已能跑纯规则流水线；站方 `@js:` 规则仍会报「后端未接」（**真错误，不静默**）。只能在 Apple 平台编译 ⇒ 沙盒验不了 ⇒ CI 要另开 macOS job |
| 12 | **换行多规则** | ⛔ **债（轻阅侧）** | 轻阅 `getElements` 对换行多规则**只返回第一行**（实测）⇒ 站方多写一行就少一半内容。自研侧已按「合并」实现（§S-FBK-04） |
| 13 | **「路径 + 尾部 `<js>` 块」复合形态** | ⛔ **缺口（4 处）** | 站方写法 `$.data.chapterList[0].volumeList<js>java.put(…);result</js>` ⇒ 引擎只认 `##正则` 和 `@js:` 后缀，**不认 `<js>` 块** ⇒ 需 JS 后端 |
| 14 | **JSONPath filter 表达式 `[?(…)]`** | ⛔ **缺口（1 处）** | `$.data.state[?(@.dataName == 'x')].items[*]` ⇒ 即**栖阅的 Sextant 过滤表达式**（Legado 安卓没有）⇒ 需接 filter 求值器 |
| 15 | **JS 后端** | ⛔ **缺口（152 条规则 / 38 个源）** | 站方 `@js:` 161 条 + `<js>` 块 66 条 ⇒ 5.8% 的规则。**38 个源只差这一件**（JM小说 20 条 / JM动漫 17 / 猫眼看书 8 …）⇒ **覆盖率天花板在这里** |

---

## 19. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-23 | **125 源规则覆盖体检**（Phase 3.5）：新增 `swift run conformance --audit <pack.json>`（**用真引擎**逐条解析 125 源 / **2755 条规则**）⇒ **79/125 源全部规则都能被引擎读懂**，38 个只差 JS 后端，**真语义缺口只剩 6 条**；据此**修掉 2 个真缺口**：① **JSONPath `.[…]`**（`$.[*]` / `$.[-1].title`，125 源 **16 处**）② **纯副作用规则**（`@put:` 整条 ⇒ 诊断不再说谎）；并给「路径 + 尾部 `<js>` 块」复合形态**单独分类**（4 处）⇒ 规格 129→**131 条**、fixture 125→**126 条**、XCTest 49→**51 项** |
| 2026-10-23 | **Phase 3（编排层）**：新增 **§17.95 S-PIPE（6 条）** + **S-FBK-04/05** + **S-VAL-01/02**，语义总数 **129 条**；实现 `BookSource`（容错解码）+ `SourceEngine`（五条流水线：分类/发现/搜索/详情/目录/正文）+ `SourceError`；**新抓到并修掉 4 个引擎语义缺口**（都是真书源逐字暴露的）：① **逗号被当兜底链** ⇒ `.catalog-section-title,.article-title a` 只出卷标题、**16 个章节全丢**；② **尾部 `##正则##`（无替换）⇒ 整条规则返回空**（spec 被拆坏）；③ **「整条规则 = 取值模式」不支持** ⇒ `"chapterName": "text"` / `"chapterUrl": "href"` 永远查不到；④ **换行多规则只跑第一行**（轻阅同款债）。⇒ **新增端到端门禁**（真书源 + 三个离线快照跑通五段流水线，8 项）+ **规则语义门禁**（12 项，专治「断言看着有、其实验不到」）；**变异测试**验证门禁确实能红（3 个变异全部被抓）；fixture 125 条 · XCTest **49 项**；⭐ **实测两条新债**：轻阅 `getElements` 对换行多规则**只返回第一行**（站方多规则就白写了） |
| 2026-10-23 | 初版。从 build214 源码 + 125 源活体体检 + 栖阅反推材料反推成规范。共 17 域 / 81 条。 |
| 2026-10-23 | **Phase 2e（宿主适配）**：新增 **§17.9 S-HOST（4 条）**；实现 `URLBuilder`（URL 规则）+ `HTTPTransport` 协议 + `CookieJar` + `PageFetcher`；把轻阅的 `AnalyzeUrl.swift` 拉进 `reference/swift/` 做**Swift 侧对拍**（12 条 URL 规则**逐字一致**，0 DIVERGE）；fixture 122 条 · XCTest 29 项；**自查抓到 3 个实现 bug**（scheme 白名单写成「所有自定义」⇒ `https:` 也放行 / `splitOptions` 用 `lastIndex` ⇒ 选项拆不出来 / Cookie 的 host 比较自己比自己 ⇒ 越权发 cookie） |
| 2026-10-23 | **Phase 2d（AST 缓存）**：新增 **S-EVAL-11**（规则 AST 可缓存）；实现 `RuleCache`（线程安全 + 容量上限 + 命中率统计）；`RuleParser` 支持注入缓存、`Evaluator` 持有缓存解析器；门禁 +7 项（**缓存前后 AST 逐字相同** / 命中 / isJSON 分键 / 只存整条规则 / 容量上限 / Evaluator 走缓存 / 可清空）；实测 **加速 ≈ 85 倍** |
| 2026-10-23 | **Phase 2c（XPath 子集）**：新增 **S-DOM-07**（8 种语法，子集照 125 源 28 条真用法定）；实现 `XPathEngine`（纯 Swift，不依赖 libxml2）；DOMNode 协议加 `children()` / `directText()`；fixture 110 条（+6 条 XPath 对拍）；**两边逐字一致 5/6** ⇒ 第 6 条是我**期望值写错**（以为 `@class='a b'` 匹配不上，**其实匹配得上**）⇒ 已更正规格与代码注释 |
| 2026-10-23 | **自查后修订**（实现 F1~F4）：新增 **S-DIA-07**（真错误 vs 没命中必须分开）+ **S-EVAL-09b**（基准类型不对 = 真错误），语义总数 **113 条**；求值器 19 处静默 `.void` **全部改成带诊断**；`EngineDiagnostic` 从「定义了不用」变成**求值器的一等输出**；XPath 分支不再骗人；attr 步补 `break`；Swift 侧新增 3 项诊断测试 + 5 条 `diagnose` 对拍用例 |
| 2026-10-23 | **Phase 2b（求值器）后修订**：新增 **§17.8 S-EVAL（10 条）** + **S-PUT-03**（`@get:` 内嵌在 URL 里轻阅也不替换 = 新债），语义总数 **111 条**；记我自己实现的 **4 个 bug**（漏「整条 {{}}」短路、漏「字面 URL」短路、JSON 空字符串判空错、正则捕获组 range 用错）；记两条新查实的差异（**`@get:` 内嵌在 URL 里轻阅也不替换**、**`text.X` 匹配完整文本 ⇒ 祖先也可能命中**） |
| 2026-10-23 | **Phase 2（DOM 层）后修订**：<br>① 新增 **§17.5 S-DOM**（DOM 层 6 条：头段/链段分流、隐式标签前缀、空 CSS 候选集、含自身、`:textEquals` 后置过滤、SwiftSoup 选型）<br>② S-SEL-01 补「完全相等比的是**完整文本** ⇒ 祖先元素也可能命中」<br>③ S-SEL-02 补「**零误伤已坐实**」（125 源：并列 class 40 处 + 纯 CSS 后代 50 处，两种都对）<br>④ S-SEL-04 记 **`@html` 语义差异**（Legado innerHTML vs 轻阅 outerHTML）—— 本项目按 Legado 语义<br>⑤ 记我自己的两个实现 bug：头段/链段混用分类器、空 CSS 候选集漏了后代（**均已修**） |
| 2026-10-23 | **符合度体检后修订**（改了 5 条，其中 2 条是我自己写错的）：<br>① **S-EXCL-01 语义改写**——`!N` 是「排除**第 N 个**（0-based）」，不是「排除前 N 个」（错在印象，已按 125 源实际用法 + 实测定准）<br>② **S-EXCL-02 撤回**——我先写「链中段排除不生效 = 债」，逐位置实测后证明**排除语法本身没问题**，不生效的是「裸标签名」那一段 ⇒ 归 S-SEL-06<br>③ 新增 **S-SEL-06**（链段里的**裸标签名**被当属性名 ⇒ 链断 ⇒ **125 源里 279 处、60 个源**）⭐ 重量级<br>④ 新增 **S-JSON-06**（`flatten()` 吃 `{title,url}` 对象的标题 = 债）<br>⑤ S-JSON-02 状态从「✅ 修好」改为「⚠️ 部分修复」 |
