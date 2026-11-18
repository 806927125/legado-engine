# Vendored 第三方源码（MIT）

本目录是**第三方 MIT 源码的原样拷贝**，作为**本包内的三个 target**（`Hitch` / `Spanker` / `Sextant`）提供给 `LegadoCore`。

## 为什么 vendored（而不是 SPM 远程依赖）
- **不联网** ⇒ 沙盒 / Linux 门禁离线也能 `swift build` ⇒ 不会因为拉不到包而红 ⭐⭐⭐
- **保持模块边界** ⇒ 三个包各自独立 target（`import Hitch` / `import Spanker` 原样保留）
  ⚠️⚠️ **不能塞进同一个模块**：`Hitch.ValueType` 与 `Spanker.ValueType` 定义**不同**
  ⇒ 同模块会「invalid redeclaration」⇒ 编译直接挂 ⭐⭐⭐

## 清单（全部 **MIT**，可商用、无 copyleft）

| 包 | 来源 | 许可 | 用途 |
|---|---|---|---|
| `Sources/Hitch/`（本包的 target `Hitch`） | https://github.com/KittyMac/Hitch | MIT（`LICENSE-Hitch.txt` = 上游 README 的许可段） | 高性能字符串 |
| `Sources/Spanker/` | https://github.com/KittyMac/Spanker | MIT（`LICENSE-Spanker.txt`） | 零拷贝 JSON 解析 |
| `Sources/Sextant/` | https://github.com/KittyMac/Sextant | MIT（`LICENSE-Sextant.txt`） | JSONPath + 过滤表达式求值 |

- ⭐ `Sextant.swift` 里的 `import Chronometer` 在上游是**未使用的**（`measure` 出现 0 次）
  ⇒ 已删除 ⇒ **不需要** Chronometer（它是 CLI 基准工具，与库无关）。

## 唯一的源码改动
1. `Sextant/Sextant.swift`：删掉未使用的 `import Chronometer`（1 行）
2. 其余文件**逐字未改**（含所有 `import Hitch` / `import Spanker`）

## 同步上游
```bash
git clone --depth 1 https://github.com/KittyMac/Sextant.git /tmp/Sextant
cp -r /tmp/Sextant/Sources/Sextant/*  Sources/Sextant/
cp /tmp/Sextant/LICENSE                  Vendor/licenses/LICENSE-Sextant.txt
sed -i "/^import Chronometer$/d" Sources/Sextant/Sextant.swift
```

## ⚠️ 许可红线
- ✅ 只许 vendor **MIT / Apache / BSD** 这类宽松许可的代码。
- ❌ **不许**把 **GPL**（如橘阅 Juyue，GPL-3.0）代码拷进来 ⇒ 会污染整个 App 的分发许可。
- ❌ **不许**从**闭源 App 的二进制**里抽源码（如阅读2.0 的 `ruleEngine.js`）⇒ 侵权。
