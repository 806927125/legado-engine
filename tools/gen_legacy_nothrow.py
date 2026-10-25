#!/usr/bin/env python3
"""
⭐⭐⭐ **生成「老引擎上不抛异常」的 API 名单** ⇒ 写进 `JSHostAPI.legacyPresentKeys`

**为什么要有这个**（2026-10-25 真机实证）：
  `java.longToast is not a function` ⇒ **站方 JS 第一句就炸** ⇒ 整条规则死定 ⭐⭐⭐
  ⇒ 根因：宿主没实现 ⇒ 包装函数抛 TypeError
  ⇒ ⭐ **但「抛不抛」不能一刀切**：
     - 老引擎上**压根没有**这个方法（`java.qread` / `java.copyText` / `java.digestHex`）
       ⇒ 站方 `try/catch` 探测平台 ⇒ **必须抛**（抛了站方才走对分支）⭐
     - 老引擎上**有**这个方法（宿主 op 缺失时 `nativeCall` 只是 resolve `{ok:false}`）
       ⇒ 老引擎上**不抛** ⇒ 新引擎也不许抛 ⇒ 否则 **站方脚本直接死** = 回归 ⭐⭐⭐

⇒ 所以名单 = **「老引擎上调用不抛异常」的方法** ⇒ 由**实测**得出（不是猜）：
   `tools/probe_legacy_java_nothrow.js` 跑老引擎 + 忠实宿主 mock ⇒ 输出 JSON
⇒ 然后 `tools/gen_legacy_nothrow.py` 把它写进 Swift 源码（**不许手写**）⭐⭐⭐

跑法：
    node tools/probe_legacy_java_nothrow.js > conformance/fixtures/legacy-java-nothrow.json
    python3 tools/gen_legacy_nothrow.py
"""
import json, io, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, 'conformance/fixtures/legacy-java-nothrow.json')
SWIFT = os.path.join(ROOT, 'Sources/LegadoCore/JS/JSHostAPI.swift')

d = json.load(open(FIX, encoding='utf-8'))
names = sorted(d['noThrow'])
if not names:
    sys.exit('❌ 名单是空的 ⇒ 探针没跑对，别把空名单写进源码')

block = []
line = ''
for n in names:
    piece = '"java.%s", ' % n
    if len(line) + len(piece) > 104:
        block.append(line.rstrip())
        line = ''
    line += piece
if line.strip():
    block.append(line.rstrip().rstrip(','))
body = '\n'.join(block)

marker_start = '    public static let legacyPresentKeys: Set<String> = ['
text = io.open(SWIFT, encoding='utf-8').read()
if marker_start in text:
    # 替换旧的整块
    i = text.index(marker_start)
    j = text.index('\n    ]', i) + len('\n    ]')
    new = (marker_start + '\n' + body + '\n    ]')
    text = text[:i] + new + text[j:]
else:
    anchor = '    /// 契约里有哪些宿主对象'
    ins = ('''    /// ⭐⭐⭐ **老引擎上「调用不抛异常」的 API**（**自动生成**，勿手改）
    ///
    /// 源：`conformance/fixtures/legacy-java-nothrow.json`
    /// ⇒ 由 `tools/probe_legacy_java_nothrow.js`（**真跑老引擎** + 忠实宿主 mock）实测得出
    /// ⇒ 再由 `tools/gen_legacy_nothrow.py` 写进本文件 ⭐⭐⭐
    ///
    /// ⚠️ **为什么要有它**（2026-10-25 真机：`java.longToast is not a function`）：
    ///   宿主没实现 ⇒ 包装函数抛 TypeError ⇒ **站方 JS 第一句就炸** ⇒ 整条规则死定 ⭐⭐⭐
    ///   ⇒ **但「抛不抛」不能一刀切**：
    ///     · 老引擎上**压根没有**这个方法 ⇒ 站方 `try/catch` 探测平台 ⇒ **必须抛**（抛了站方才走对分支）⭐
    ///     · 老引擎上**有**这个方法（宿主 op 缺失时 `nativeCall` 只 resolve `{ok:false}` ⇒ **不抛**）
    ///       ⇒ 新引擎也**不许抛** ⇒ 否则站方脚本直接死 = **回归** ⭐⭐⭐
    ///   ⇒ 名单内的：**宿主没实现 ⇒ 静默返回 undefined**（与老引擎一致）
    ///   ⇒ 名单外的：**照旧抛 TypeError**（与老引擎一致）
    public static let legacyPresentKeys: Set<String> = [
''' + body + '''
    ]

''' + anchor)
    text = text.replace(anchor, ins, 1)

io.open(SWIFT, 'w', encoding='utf-8').write(text)
print(f'✅ 写入 {len(names)} 个 legacyPresentKeys（老引擎上不抛）')
