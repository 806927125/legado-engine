#!/usr/bin/env python3
"""
⭐ **重扫 125 源包 ⇒ 生成 `conformance/fixtures/js-api-usage.json`**

⚠️ **为什么要有这个脚本**（2026-10-25 实证）：
   契约清单是**手工维护**的 ⇒ 漏登记 `source.get` / `source.put`（**125 源实测 129 处**）
   ⇒ 门禁（契约 ⊇ 真实用量）**压根没机会抓到** ⇒ 站方调用 TypeError ⇒ 静默失效 ⭐⭐⭐
   ⇒ 根治：**清单从源包自动扫**，不手工维护 ⭐

用法：
    python3 tools/gen_js_api_usage.py --sources <125源包目录或单个json> [--out <输出>]

⚠️ 只收「站方真调用」的 API（`java.x()` / `source.x()` / `cookie.x()`）⇒
   契约要覆盖的是这些 ⇒ 属性（`book.x`）不在本脚本范围内（另有清单）。
"""
import argparse, json, os, re, glob, collections

CALL = re.compile(r'\b(java|source|cookie)\.([a-zA-Z_]\w*)\s*\(')

def scan(paths):
    use = collections.Counter()
    for path in paths:
        files = glob.glob(os.path.join(path, '*.json')) if os.path.isdir(path) else [path]
        for f in files:
            try:
                d = json.load(open(f, encoding='utf-8'))
            except Exception:
                continue
            arr = d if isinstance(d, list) else d.get('data', [])
            for s in arr:
                blob = json.dumps(s, ensure_ascii=False)
                for m in CALL.finditer(blob):
                    use[f"{m.group(1)}.{m.group(2)}"] += 1
    return use

def load_legacy(path=None):
    """老引擎（轻阅 reference/js）支持的宿主 API 对象清单"""
    if path is None:
        path = os.path.join(os.path.dirname(__file__), '..',
                            'conformance/fixtures/legacy-host-api.json')
    try:
        d = json.load(open(path, encoding='utf-8'))
    except Exception:
        return {}
    return {k: set(v) for k, v in d.items() if k in ('java', 'source', 'cookie')}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sources', required=True, help='125 源包目录或单个 json')
    ap.add_argument('--out', default=os.path.join(os.path.dirname(__file__), '..',
                                                  'conformance/fixtures/js-api-usage.json'))
    ap.add_argument('--legacy', default=None,
                    help='老引擎能力清单（默认 conformance/fixtures/legacy-host-api.json）')
    ap.add_argument('--all', action='store_true',
                    help='不按老引擎过滤（把站方用到、老引擎没有的也收进来 ⇒ 会逼着实现它们）')
    a = ap.parse_args()
    use = scan([a.sources])
    legacy = load_legacy(a.legacy)
    if legacy and not a.all:
        # ⭐ 只收「站方真用 ∧ 老引擎支持」的
        #   ⇒ 老引擎没有的（java.copyText 等）**不搬**：搬了会改变行为（老引擎上它们是 undefined）⭐
        use = collections.Counter(
            {k: v for k, v in use.items()
             if k.split('.', 1)[1] in legacy.get(k.split('.', 1)[0], set())})
    p = os.path.abspath(a.out)
    d = json.load(open(p, encoding='utf-8')) if os.path.exists(p) else {'methods': [], 'properties': []}
    old = set(d.get('methods', []))
    if legacy and not a.all:
        # ⭐ **强制清单 = 站方真用 ∧ 老引擎支持**（交集）
        #   ⇒ 老引擎没有的（java.copyText / java.qread / …）**不强制**：
        #     引擎实现了就留着（站方能用，比老引擎强），没实现也不该被门禁逼着做 ⭐
        keep = {k for k in (old | set(use.keys()))
                if k.split('.', 1)[1] in legacy.get(k.split('.', 1)[0], set())}
    else:
        keep = old | set(use.keys())
    d['methods'] = sorted(keep)
    d['usageCounts'] = dict(use.most_common())
    d['note'] = (d.get('note', '') +
                 f" ｜ 用 tools/gen_js_api_usage.py 从 {os.path.basename(a.sources)} 重扫（{len(use)} 个 API）⭐")
    json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(f"✅ 写入 {p}：方法 {len(d['methods'])} 个（本次扫到 {len(use)} 个）")

if __name__ == '__main__':
    main()
