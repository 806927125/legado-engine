# JSC（JavaScriptCore）后端：真机验证笔记

> 记录 2026-10-23 把它从「写完就盲」推到「macOS CI 能验」的过程。
> ⭐ **这轮的价值不在代码，在「macOS 上才暴露的那几类问题」。**

## 为什么必须要有 macOS CI

JSC 只能在 Apple 平台编译 ⇒ Linux 沙盒里：
- `swiftc -parse` **只能查语法**（查不出类型/API/签名）
- ⚠️ **「能 parse 通过」≠「能编译通过」** ⇒ 我连续 6 轮 CI 才编过

⇒ **CI 加了 `jsc` job（`macos-latest`）**：
```yaml
jsc:
  runs-on: macos-latest
  steps:
    - uses: actions/checkout@v4
    - run: swift --version          # ⚠️ 不用 swift-actions（见下）
    - run: set -o pipefail; swift build 2>&1 | tee jsc-build.log
    - run: set -o pipefail; swift test --filter JSCExecutorTests 2>&1 | tee jsc-test.log
    - uses: actions/upload-artifact@v4   # 日志归档（排查用）
```

## ⚠️ 踩到的 9 个坑（**全在 Linux 沙盒里看不出来**）

| # | 坑 | 症状 | 修法 |
|---|---|---|---|
| 1 | **`Package.swift` 没声明平台版本** | `the library 'LegadoCore' requires macos 10.13, but depends on the product 'SwiftSoup' which requires macos 12.0` | `platforms: [.macOS(.v12), .iOS(.v15)]`（Linux 是默认平台，不用声明） |
| 2 | **swift-actions 装的 Swift 与 runner 的 Xcode SDK 版本不匹配** | `this SDK is not supported by the compiler`（SDK 是 6.3.2 编的，编译器是 6.1.2） | **别用 swift-actions** ⇒ 用 runner 自带的 swift |
| 3 | **`\| tee` 吞掉 exit code** | 编译失败被标成 success ⇒ 白等一轮 | `set -o pipefail` |
| 4 | **同名类型冲突** | 引擎的 `JSContext` vs `JavaScriptCore.JSContext` ⇒ 解析到引擎那个 ⇒ 一串莫名错误 | 引擎那个改名 **`JSRunContext`**；JSC 文件里一律**全限定名** |
| 5 | **同名类型冲突（系统类型）** | 引擎的 `Category` vs macOS Foundation 的 `Category` ⇒ `'Category' is ambiguous` | 改名 **`SourceCategory`** |
| 6 | **Xcode 26 的 JSC 换成 Swift-native 实现** | `JSValue` 没有 `newObject` / `newArray` / `nullIn` 这些静态工厂 | **只依赖最基础的三个 API**（`evaluateScript` / `setObject(_:forKeyedSubscript:)` / `setObject(_:at:)`）⇒ 一律用 `evaluateScript` 现场造对象 |
| 7 | **Swift 闭包不能直接当 `Any!` 传给 JSC** | 运行时 `TypeError: Cannot convert primitive value` | `unsafeBitCast(block, to: AnyObject.self)`；**且参数只能用 ObjC 可桥接的类型** ⇒ 数组/对象不行 ⇒ 改走 **JSON 字符串通道** |
| 8 | **Swift 6.2+ 不允许对 IUO 用 `!`** | `using '!' is not allowed here` | block 返回类型改 `JSValue?`；`guard let` 解包 |
| 9 | **`forKeyedSubscript` 不支持 `a.b` 路径** / **`JSONSerialization` 只接受容器** | 属性设不进去 / 顶层标量序列化失败 | 属性：先 `objectForKeyedSubscript` 拿对象再逐个 set；标量：**包一层数组**返回，JS 侧取 `[0]` |

## ⭐ 求值形态（最要紧的一条）

**站方 JS 要的是 Script 的完成值（末行表达式的值）**：
- ✅ `eval("1 + 2")` ⇒ **3**
- ❌ `(function(){ 1 + 2 })()` ⇒ **undefined**（函数体要显式 return！）

⇒ **不要包成函数体**。代价：顶层 `return` 是语法错 ⇒ 但 Legado/Rhino 也是 `eval` ⇒ **两端一致** ✔

⇒ 站方自己给 `result` 赋值的情况**天然正确**：`result = String(...)` 作为末行 ⇒ 赋值表达式的值 = 赋的值。

## 宿主注入的 JSON 通道

因为 ObjC block 桥接不了 Swift 数组/对象 ⇒ 只能走「全是 String」的通道：

```
JS 侧包装： java.getString = function(){ var __a = slice.call(arguments);
            var __t = __hostJSON('java','getString',JSON.stringify(__a));
            var __r = JSON.parse(__t); return __r && __r.length!==undefined ? __r[0] : undefined; }
Swift 侧：  __hostJSON(obj, method, argsJSON) -> String
            解析 argsJSON ⇒ 调宿主 ⇒ 结果**包一层数组**序列化成 JSON 文本
```

⚠️ **已知限制（未修）**：`java.*` 的**参数传递**还有问题（宿主收到的第一个参数是空的）
⇒ `JSCExecutorTests.testJavaAPIIsInjected` 用 `XCTSkip` **标成已知限制**（**不假装通过**）
⇒ 怀疑点：包装函数的参数个数（写死 `a0..a3` 时站方传 1 个 ⇒ 后面的变 undefined ⇒ `JSON.stringify` 变 null）
⇒ 改用 `arguments` 后**反而 5 个全挂** ⇒ 说明还有别的问题，**别急着改** ⇒ 先加诊断日志再动。

## 给下次的纪律

1. ⭐ **平台专属代码（Apple / Android / Windows）必须有对应的 CI job**，否则等于盲写
2. ⭐ **改 SwiftPM 的 `platforms` 声明** ⇒ 可能在别的平台上直接编不过
3. ⭐ **CI 里凡是用 `| tee` 的步骤，都要 `set -o pipefail`** ⇒ 否则失败被伪装成成功
4. ⭐ **引擎自己的类型名要避开系统同名**（`JSContext` / `Category` / `Task` / `Page`…）
5. ⭐ **跨平台库升级会删 API**（Xcode 26 的 JSC）⇒ 只依赖最基础、最稳定的那些
6. ⭐ **失败要如实标**（`XCTSkip` + 文档写清根因）⇒ **不许让门禁「假装绿」**
