#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""⭐ 生成「宿主 API 能力清单」—— 宿主 App 接引擎时照着做。

⚠️ **自动生成**（从 `JSHostAPI.swift` 的契约 + `SourceEngine.engineJava` 的实现里扫出来）
   ⇒ 改了代码重跑一次就同步 ⇒ 不会过期 ⭐

用法：python3 tools/gen_host_api_guide.py > docs/HOST-API-GUIDE.md
"""
import re, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, 'Sources/LegadoCore/JS/JSHostAPI.swift')
ENG = os.path.join(ROOT, 'Sources/LegadoCore/Pipeline/SourceEngine.swift')
USAGE = os.path.join(ROOT, 'conformance/fixtures/js-api-usage.json')
OUT = os.path.join(ROOT, 'docs/HOST-API-GUIDE.md')

# 宿主侧要实现的（说明写给宿主看）
HOST_NOTE = {
    'toast': '弹一个短提示（`notify`）',
    'longToast': '弹一个长提示',
    'log': '写引擎日志（用户能在「诊断」里看到）',
    'getCookie': '读 cookie 罐',
    'setCookie': '写 cookie 罐',
    'getWebViewUA': '给站方 JS 一个可用的 User-Agent',
    'startBrowser': '开浏览器（**异步**，引擎内只有它例外）',
    'startBrowserAwait': '开浏览器并**同步**等结果（登录交接用）',
    'startBrowserDp': '开浏览器（带 DP 参数）',
    'showBrowser': '显示浏览器',
    'showReadingBrowser': '阅读模式浏览器',
    'reLoginView': '重新登录（弹登录面板）',
    'searchBook': '搜书（跳到搜索页）',
    'getElement': '在当前页 DOM 里取元素（**需要 document 代理**）',
    'getElements': '同上（复数）',
    'setContent': '把内容写进 WebView',
    'createSymmetricCrypto': '对称加密（站方签名用）',
    'deviceID': '设备 ID',
    'androidId': 'Android ID',
    't2s': '**繁简转换**（需要词库）',
    'refreshExplore': '刷新发现页（UI 动作）',
    'refreshTocUrl': '刷新目录 URL（UI 动作）',
    'connect': '打开某个页面（UI 动作）',
    'ajaxAll': '一次发多个请求（返回数组）',
    'post': 'POST 请求（第二参是 body 字符串，**语义与 ajax 的 options 不同**）',
    'qread': '起 QQ 阅读',
}

def main():
    api = open(API, encoding='utf-8').read()
    eng = open(ENG, encoding='utf-8').read()
    usage = json.load(open(USAGE, encoding='utf-8'))
    used = set(usage.get('methods', []))

    contract = re.findall(r'\.init\(object: "java", name: "([^"]+)", kind: \.(\w+)\)', api)
    # 引擎实现的：从 engineJava 的 switch 里扫 case
    m = re.search(r'public func engineJava\(.*?\n    \}', eng, re.S)
    body = m.group(0) if m else ''
    engine_impl = set(re.findall(r'case "([A-Za-z_]\w+)"', body))

    rows_engine, rows_host = [], []
    for name, kind in contract:
        if kind != 'method':
            continue
        star = '★' if 'java.' + name in used else ' '
        if name in engine_impl:
            rows_engine.append((name, star, used and ('java.'+name in used)))
        else:
            rows_host.append((name, star, 'java.'+name in used, HOST_NOTE.get(name, '（宿主实现）')))

    out = []
    out.append('# 宿主 API 能力清单（`java.*`）\n')
    out.append('> ⭐ **本文件是自动生成的**（`tools/gen_host_api_guide.py`）⇒ 改代码后重跑即可同步。\n')
    out.append('> 依据：125 源真实书源扫描（`conformance/fixtures/js-api-usage.json`）+ 引擎实现。\n')
    out.append('\n## 一句话架构\n')
    out.append('```\n'
               '站方 JS  ──►  java.xxx(...)  ──►  引擎侧 handler（能做的）\n'
               '                                    └─► 返回 nil ⇒ 落回宿主 provider\n'
               '```\n')
    out.append('\n⭐ **引擎内部全同步** ⇒ `java.ajax` 能**同步发请求直接返回正文**')
    out.append('⇒ **不需要「两遍跑」机制**（那是 WKWebView 异步桥的补丁）。\n')
    out.append('\n## ① 引擎已经做了（宿主**不用实现**）\n')
    out.append('| API | 真实书源在用 | 说明 |')
    out.append('|---|---|---|')
    notes = {
        'ajax': '同步发请求；站方第二个参数 `{method,body,headers}` ⇒ 转成 URL 规则后缀（复用 URLBuilder 编码语义）；`data:` 伪 URL **不发请求**',
        'md5Encode': 'MD5（小写 hex）；引擎自实现（Foundation 没有 MD5）',
        'base64Encode': '标准 Base64',
        'base64Decode': '解不了 ⇒ **空串**（明确失败，不返回乱码）',
        'hexDecodeToString': '**双语义**：不是合法 hex 就按 base64 再试一次',
        'randomUUID': 'v4 形状',
        'toNumChapter': '文本里的中文数字批量转阿拉伯数字',
        'getString': '实参以 `$` 开头 ⇒ **对基准做 JSONPath**；否则读源级变量',
        'get': '读源级变量（可带默认值）',
        'put': '写源级变量（**共享存储** ⇒ 后续规则读得到）',
        'timeFormat': 'epoch 毫秒 → 默认 `"yyyy-MM-dd HH:mm:ss"`（本地时区）',
        'timeFormatUTC': 'epoch 毫秒 + pattern + **时区偏移小时**（如 8 = UTC+8）',
    }
    for name, star, _u in sorted(rows_engine, key=lambda r: (not r[2], r[0])):
        out.append(f'| `java.{name}` | {star} | {notes.get(name, "")} |')
    out.append('\n## ② 宿主要实现（引擎**不接管** ⇒ 返回 nil ⇒ 落回你）\n')
    out.append('| API | 真实书源在用 | 你要做的 |')
    out.append('|---|---|---|')
    for name, star, _used, note in sorted(rows_host, key=lambda r: (not r[2], r[0])):
        out.append(f'| `java.{name}` | {star} | {note} |')
    out.append('\n> ★ = 125 个真实书源里**实际在用**。')
    out.append('>\n> ⚠️ **契约漏一个 = JS 侧不生成那个包装函数** ⇒ 站方调用报')
    out.append('> 「`undefined is not a function`」⇒ **静默失效**。')
    out.append('> ⇒ 契约清单必须 ⊇ 真实用量（门禁 `JSHostAPITests` 在守）。\n')
    open(OUT, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
    print('wrote', OUT)

if __name__ == '__main__':
    main()
