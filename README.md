# legado-engine

> **自研 Legado 兼容规则引擎** —— 从轻阅（qireaderlite）里独立出来的引擎项目。
>
> 目标：做一个**语义精确、可测试、不依赖浏览器**的通用 Legado 规则引擎，
> 让「几千个现成书源」能在一个宿主里稳定跑起来。

---

## 为什么独立成项目

轻阅（iOS App）里那套引擎是**跑得通的实现**，不是**有定义的东西**：

| 问题 | 表现 |
|---|---|
| 规则解析散落在 3 个文件 | `parseRule` / `splitTopLevel` / `stripModeTail` / `splitTopLevelRules` 各切各的，同一个 `\|\|` 三种切法 |
| 语义靠注释维持 | `result` 的三层含义、`!N` 的索引含义，全靠人记 ⇒ 改一次炸一批 |
| 沙盒 ≠ 真机 | 门禁跑 jsdom，真机跑 WKWebView ⇒ **同一 bug 沙盒不复现**（栽过两次） |
| 零诊断 | 错了没人知道 ⇒ 静默失效 |

⇒ 所以：**规格独立、实现独立、验收独立**。App 只是它的一个宿主。

---

## 项目结构

```
legado-engine/
├── Package.swift                    # Swift Package（纯 Foundation，Linux 可编可跑）
├── Sources/
│   ├── LegadoCore/                  # ⭐ 语义内核（自研主体）
│   │   ├── Rule/
│   │   │   ├── RuleMode.swift       #   模式判定（§S-CLS，19 条）
│   │   │   ├── RuleNode.swift       #   AST + 链段分类（§S-SEL-06 ⭐）
│   │   │   └── RuleParser.swift     #   规则 → AST（§S-FBK / §S-EXCL / §S-RGX）
│   │   ├── Context/
│   │   │   └── RuleBase.swift       #   基准分层（§S-RES ⭐⭐⭐）+ 宿主对象
│   │   ├── Support/
│   │   │   ├── JSONValue.swift      #   最小 JSON 值（区分 int/double/bool）
│   │   │   └── RuleValue.swift      #   值系统（字段→String / 列表→[RuleValue]）
│   │   └── Diagnostics/
│   │       └── EngineDiagnostic.swift  # 诊断是一等公民（§S-DIA）
│   └── Conformance/main.swift       # 对拍运行器（Swift 侧）
├── Tests/LegadoCoreTests/           # XCTest（7 项，0.1 秒）
├── reference/js/                    # ⭐ 轻阅现有 JS 引擎（**只读参考，不改**）
├── conformance/
│   ├── fixtures/semantics-cases.json  # 79 条语义用例（两边共用同一份）
│   ├── js-runner.js                 # 对拍运行器（JS 侧）
│   └── out/report.md                # 对拍报告（自动生成）
├── docs/
│   ├── legado-semantics.md          # ⭐ 语义规格（17 域 81 条）
│   ├── 现状符合度报告.md              # 轻阅现状 vs 规格
│   └── architecture.md               # 目标架构
└── tools/conformance-diff.sh        # 一键对拍
```

---

## CI

每次 push 到 `main` 自动跑：**编译 → `swift test` → 双实现对拍** ⇒ 绿/红一眼可见。

> 第一次跑会拉 Swift 工具链（877MB），之后有缓存。
> 报告在 Actions 的 **Artifacts → conformance-report**。

⚠️ Actions **只认默认分支上的 workflow** —— 改默认分支前，workflow 也要同步过去。

---

## ⭐ 核心工作流：规格 → 双实现 → 对拍

```
        docs/legado-semantics.md
        （规格：每条带依据 + 现状 + 门禁位置）
                    │
                    ▼
     conformance/fixtures/semantics-cases.json
     （同一份 fixture，两边共用）
              ┌─────┴─────┐
              ▼           ▼
      Swift 自研实现    JS 参考实现
     （照规格写的）    （轻阅现有，只读）
              └─────┬─────┘
                    ▼
         tools/conformance-diff.sh
                    ▼
         差异 = 债（要么是参考实现的 bug，
                  要么是规格写错了 —— 两边都要人看一眼）
```

⭐ **为什么要两套实现**：
1. 照着别人的实现抄 ⇒ 抄来的 bug 一起抄
2. 照着规格写 + 与参考实现对拍 ⇒ **差异就是待查清单**
3. 规格也可能写错 ⇒ 对拍会把「规格 vs 两边都错」也标出来 ⇒ 逼人去看

---

## 跑起来

### 环境

```bash
# Swift 工具链（Linux；877MB）
mkdir -p /workspace/.toolchain && cd /workspace/.toolchain
curl -sL --retry 5 -o s.tar.gz https://download.swift.org/swift-6.1.2-release/debian12/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-debian12.tar.gz
tar xzf s.tar.gz && mv swift-6.1.2-RELEASE-debian12 swift

# Node 依赖（jsdom：给 JS 参考实现提供 DOM）
npm install --registry=https://registry.npmmirror.com
```

### 三个命令

```bash
export LD_LIBRARY_PATH=/workspace/.toolchain/swift/usr/lib/swift/linux:$LD_LIBRARY_PATH

swift build                      # 编译语义内核（~4 秒）
swift test                       # 跑 7 项规格测试（~0.1 秒）
bash tools/conformance-diff.sh   # 双实现对拍 → conformance/out/report.md
```

---

## 当前进度

| 切片 | 状态 | 说明 |
|---|---|---|
| **Phase 0** 语义规格 | ✅ | 17 域 81 条 + 79 条 fixture + 符合度报告 |
| **Phase 1** 规则前端（AST） | ✅ **进行中** | 模式判定、顶层切分、链段分类、排除语法、AST 结构 |
| Phase 2 求值器 + DOM | ⬜ | 需要注入 DOM 后端（SwiftSoup / jsoup） |
| Phase 3 JS 后端 | ⬜ | JSC + 宿主绑定 + 同步 document 代理 |
| Phase 4 编排层 | ⬜ | 搜索/发现/详情/目录/正文 五条流水线 |
| Phase 5 切默认 | ⬜ | 宿主换成自研引擎 |

### 对拍现状

```
用例总数 104 · 两边一致 86 · 存在差异 18
Swift（自研）：104 通过 / 0 不符合   ✅
JS（轻阅参考）：86 通过 / 18 不符合
```

**18 条差异全部是「轻阅的 bug」**，其中 12 条同一个根因：

> 链段里的**裸标签名**（`@li` / `@a` / `@img` / `@span` / `@p` / `@dd` …）被当成了**属性名**
> ⇒ 链断 ⇒ 取到父元素整体
> ⇒ **125 源里 279 处、60 个源（48%）** 受影响
> ⇒ 症状：**目录只有 1 章** / 搜索只出 1 本 / 发现页出不来 / 封面空白

自研实现按规格已经修对（`ChainSegmentClassifier.classify`），并有**双向回归锁**：
裸标签名必须是子选择器、属性白名单必须还是属性后缀（别把修复做过头）。

⭐ **行为对拍**（`domSelect` / `evalOne` / `getElements` 用例）：真 HTML + 125 源真规则 ⇒ 比**节点数 + 文本**。
例：`class.catalog_ls@li`（神马小说）
- 轻阅 ⇒ 1 个节点，文本是 `<ul>` 的整体文本（链断）
- 自研 ⇒ 2 个节点（第一章 / 第二章）✅

⭐ **求值对拍**（`evalOne` / `getElements`，41 条）：规则 + 基准 + 上下文 ⇒ 值。
⇒ 这一轮就把轻阅的 4 条求值层 bug 钉出来了：`@get:` 内嵌在 URL 里不替换、
JSON 对象被 flatten 吃掉标题、裸标签名链断、`||` 兜底链不跳空串。

⭐ **诊断对拍**（`diagnose`，5 条）：规则 + 基准 ⇒ **结论分级** + 是不是**真错误**。
⇒ 轻阅**没有**这一层（诊断只会说「0 命中」）⇒ 这是自研引擎相对轻阅的核心差异化 ⭐

---

## 铁律

1. **规格先行**：任何行为改动，先在 `docs/legado-semantics.md` 写条目，再写实现。
2. **断言作用于从 fixture 解析出来的规则**，不是复述实现意图。
3. **门禁要先红一次**才证明有效。
4. **`Core` 保持纯 Foundation** ⇒ Linux 沙盒能真编真跑 ⇒ 3 秒反馈。
5. **宿主对象必须真的传进来**（`book` / `source`）—— 少传一个 ⇒ 整条规则静默失效。
6. **不许静默失败**：失败要带原因（`EngineDiagnostic.Failure`）。
7. **诊断必须走真实路径** —— 测 A 别说 B 的问题。

---

## 文档

- [`docs/legado-semantics.md`](docs/legado-semantics.md) —— 语义规格（**先看这个**）
- [`docs/现状符合度报告.md`](docs/现状符合度报告.md) —— 轻阅现状 vs 规格
- [`docs/architecture.md`](docs/architecture.md) —— 目标架构
- [`conformance/out/report.md`](conformance/out/report.md) —— 双实现对拍报告（自动生成）

---

## 与轻阅的关系

- `reference/js/` 是**轻阅现有引擎的快照**，只读，**不在这个项目里改它**。
- 轻阅的修法（裸标签名、flatten 吃标题等）**在这个项目里已经按规格修对**，
  但**轻阅本体还没改** —— 要不要回灌、什么时候回灌，是轻阅那边的事。
- 本项目与轻阅**没有代码依赖**：轻阅可以继续用自己的 JS 引擎，
  也可以在准备好之后切到自研引擎（`LegadoCore` 是纯 Foundation，理论上可以直接被
  轻阅的 `Core/` 引用）。
