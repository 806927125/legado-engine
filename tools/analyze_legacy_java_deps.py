#!/usr/bin/env python3
"""⭐ 老引擎 java.* 方法的「宿主依赖」静态分析

- 老引擎 `reference/js/java-api.js` 里每个方法 ⇒ 它最终调哪些 `nativeCall('op')`
- 宿主(轻阅 App)真实实现的 op ⇒ 从 Swift 源码扫 `case "op"`
- ⇒ **老引擎能调通** = 它依赖的 op 宿主都有(或它不依赖宿主)
- ⇒ 与新引擎(引擎内实现 ∪ 宿主实现)对比 ⇒ **真洞**
"""
import re, io, json, os, collections

ENG = '/workspace/legado-engine'
APP = '/workspace/qireaderlite'

# ---------- ① 老引擎 java 方法 → 依赖的 nativeCall op ----------
j = io.open(os.path.join(ENG, 'reference/js/java-api.js'), encoding='utf-8').read()
methods = {}
for m in re.finditer(r'^\s{4}(\w+):\s*function\s*\(', j, re.M):
    name = m.group(1)
    i = j.index('{', m.end())
    d = 1; k = i
    while d and k < len(j):
        if j[k] == '{': d += 1
        elif j[k] == '}': d -= 1
        k += 1
    body = j[i:k]
    ops = set(re.findall(r"nativeCall\(\s*'([^']+)'", body))
    methods[name] = ops

# ---------- ② 宿主(轻阅 App)实现的 op ----------
host_ops = set()
for root, _, files in os.walk(os.path.join(APP, 'QiReaderLite')):
    for f in files:
        if not f.endswith('.swift'): continue
        s = io.open(os.path.join(root, f), encoding='utf-8').read()
        host_ops |= set(re.findall(r'case\s+"(\w+)"', s))
# 轻阅 JS 侧也会注册一些 op（engine.js 里的 nativeCall 目标）
for f in ('engine.js', 'java-api.js', 'source-api.js'):
    p = os.path.join(ENG, 'reference/js', f)
    if os.path.exists(p):
        s = io.open(p, encoding='utf-8').read()
        host_ops |= set(re.findall(r"__qrInvoke\(\s*'([^']+)'", s))

# ---------- ③ 新引擎：引擎内实现的 java 方法 ----------
src = io.open(os.path.join(ENG, 'Sources/LegadoCore/Pipeline/SourceEngine.swift'), encoding='utf-8').read()
body = src.split('public func engineJava')[1].split('\n    }')[0]
eng_impl = set()
for mm in re.finditer(r'case\s+((?:"\w+"\s*,?\s*)+):', body):
    eng_impl |= set(re.findall(r'"(\w+)"', mm.group(1)))

# 契约
sw = io.open(os.path.join(ENG, 'Sources/LegadoCore/JS/JSHostAPI.swift'), encoding='utf-8').read()
contract = set(re.findall(r'object:\s*"java",\s*name:\s*"(\w+)"', sw))

# 站方用量
u = json.load(open(os.path.join(ENG, 'conformance/fixtures/js-api-usage.json'), encoding='utf-8'))
usage = u.get('usageCounts', {})

def callable_in_legacy(name):
    """老引擎上这个方法能不能调通：不依赖宿主 op，或依赖的 op 宿主都有"""
    if name not in methods: return False, '老引擎 java 对象上没有'
    ops = methods[name]
    missing = sorted(o for o in ops if o not in host_ops)
    if missing: return False, '宿主缺 op: ' + ','.join(missing)
    return True, ('依赖 ' + ','.join(sorted(ops)) if ops else '纯 JS')

rows = []
for name in sorted(methods):
    ok, why = callable_in_legacy(name)
    if not ok: continue
    new_ok = (name in eng_impl) or (name in host_ops)
    rows.append((name, why, new_ok, usage.get('java.' + name, 0)))

holes = [r for r in rows if not r[2]]
print("=== 老引擎能调通 %d 个；其中新引擎没覆盖 %d 个 ===" % (len(rows), len(holes)))
print()
print("%-24s %-42s %s" % ("方法", "老引擎依赖", "站方用量"))
for name, why, new_ok, u in sorted(holes, key=lambda r: -r[3]):
    print("%-24s %-42s %s 处%s" % ('java.' + name, why, u, "   ⭐老引擎能调通 ⇒ 新引擎必须能调通" if u else ""))
print()
print("=== 已覆盖（不需要动）===")
print(', '.join('java.' + r[0] for r in rows if r[2]))
json.dump({r[0]: {'legacy': r[1], 'covered': r[2], 'usage': r[3]} for r in rows},
          open('/tmp/legacy-java-calls.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
