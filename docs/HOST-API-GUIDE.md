# 宿主 API 能力清单（`java.*`）

> ⭐ **本文件是自动生成的**（`tools/gen_host_api_guide.py`）⇒ 改代码后重跑即可同步。

> 依据：125 源真实书源扫描（`conformance/fixtures/js-api-usage.json`）+ 引擎实现。


## 一句话架构

```
站方 JS  ──►  java.xxx(...)  ──►  引擎侧 handler（能做的）
                                    └─► 返回 nil ⇒ 落回宿主 provider
```


⭐ **引擎内部全同步** ⇒ `java.ajax` 能**同步发请求直接返回正文**
⇒ **不需要「两遍跑」机制**（那是 WKWebView 异步桥的补丁）。


## ① 引擎已经做了（宿主**不用实现**）

| API | 真实书源在用 | 说明 |
|---|---|---|
| `java.ajax` | ★ | 同步发请求；站方第二个参数 `{method,body,headers}` ⇒ 转成 URL 规则后缀（复用 URLBuilder 编码语义）；`data:` 伪 URL **不发请求** |
| `java.base64Decode` | ★ | 解不了 ⇒ **空串**（明确失败，不返回乱码） |
| `java.base64Encode` | ★ | 标准 Base64 |
| `java.get` | ★ | 读源级变量（可带默认值） |
| `java.getString` | ★ | 实参以 `$` 开头 ⇒ **对基准做 JSONPath**；否则读源级变量 |
| `java.hexDecodeToString` | ★ | **双语义**：不是合法 hex 就按 base64 再试一次 |
| `java.md5Encode` | ★ | MD5（小写 hex）；引擎自实现（Foundation 没有 MD5） |
| `java.put` | ★ | 写源级变量（**共享存储** ⇒ 后续规则读得到） |
| `java.randomUUID` | ★ | v4 形状 |
| `java.timeFormat` | ★ | epoch 毫秒 → 默认 `"yyyy-MM-dd HH:mm:ss"`（本地时区） |
| `java.toNumChapter` | ★ | 文本里的中文数字批量转阿拉伯数字 |

## ② 宿主要实现（引擎**不接管** ⇒ 返回 nil ⇒ 落回你）

| API | 真实书源在用 | 你要做的 |
|---|---|---|
| `java.ajaxAll` | ★ | 一次发多个请求（返回数组） |
| `java.androidId` | ★ | Android ID |
| `java.connect` | ★ | 打开某个页面（UI 动作） |
| `java.createSymmetricCrypto` | ★ | 对称加密（站方签名用） |
| `java.deviceID` | ★ | 设备 ID |
| `java.digestHex` | ★ | （宿主实现） |
| `java.getAbsoluteURL` | ★ | （宿主实现） |
| `java.getCookie` | ★ | 读 cookie 罐 |
| `java.getElement` | ★ | 在当前页 DOM 里取元素（**需要 document 代理**） |
| `java.getElements` | ★ | 同上（复数） |
| `java.getWebViewUA` | ★ | 给站方 JS 一个可用的 User-Agent |
| `java.log` | ★ | 写引擎日志（用户能在「诊断」里看到） |
| `java.longToast` | ★ | 弹一个长提示 |
| `java.post` | ★ | POST 请求（第二参是 body 字符串，**语义与 ajax 的 options 不同**） |
| `java.qread` | ★ | 起 QQ 阅读 |
| `java.reLoginView` | ★ | 重新登录（弹登录面板） |
| `java.refreshExplore` | ★ | 刷新发现页（UI 动作） |
| `java.refreshTocUrl` | ★ | 刷新目录 URL（UI 动作） |
| `java.searchBook` | ★ | 搜书（跳到搜索页） |
| `java.setContent` | ★ | 把内容写进 WebView |
| `java.showBrowser` | ★ | 显示浏览器 |
| `java.showReadingBrowser` | ★ | 阅读模式浏览器 |
| `java.startBrowser` | ★ | 开浏览器（**异步**，引擎内只有它例外） |
| `java.startBrowserAwait` | ★ | 开浏览器并**同步**等结果（登录交接用） |
| `java.startBrowserDp` | ★ | 开浏览器（带 DP 参数） |
| `java.t2s` | ★ | **繁简转换**（需要词库） |
| `java.timeFormatUTC` | ★ | （宿主实现） |
| `java.toast` | ★ | 弹一个短提示（`notify`） |

> ★ = 125 个真实书源里**实际在用**。
>
> ⚠️ **契约漏一个 = JS 侧不生成那个包装函数** ⇒ 站方调用报
> 「`undefined is not a function`」⇒ **静默失效**。
> ⇒ 契约清单必须 ⊇ 真实用量（门禁 `JSHostAPITests` 在守）。

