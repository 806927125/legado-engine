#!/usr/bin/env bash
# ===============================================================
# **双实现对拍**
#
# 同一份 fixture ⇒ Swift 新实现（照规格写的） 与 JS 参考实现（轻阅现有引擎）各跑一遍
# ⇒ 输出差异报告：**差异 = 债**。
#
# 跑法：bash tools/conformance-diff.sh [fixture.json]
# ===============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FIXTURE="${1:-conformance/fixtures/semantics-cases.json}"
OUT_DIR="$ROOT/conformance/out"
mkdir -p "$OUT_DIR"

SWIFT_BIN="${SWIFT_BIN:-/workspace/.toolchain/swift/usr/bin/swift}"
export LD_LIBRARY_PATH="${SWIFT_TOOLCHAIN_LIBS:-/workspace/.toolchain/swift/usr/lib/swift/linux}:${LD_LIBRARY_PATH:-}"

echo "=== 1/4 编译 Swift 侧 ==="
if [ -x "$SWIFT_BIN" ]; then
  "$SWIFT_BIN" build 2>&1 | tail -2
  "$SWIFT_BIN" run conformance "$FIXTURE" > "$OUT_DIR/swift.jsonl" 2> "$OUT_DIR/swift.err"
  SWIFT_LINE=$(tail -1 "$OUT_DIR/swift.err")
else
  echo "⚠️ 找不到 swiftc（$SWIFT_BIN）⇒ 跳过 Swift 侧"
  : > "$OUT_DIR/swift.jsonl"
  SWIFT_LINE="(跳过)"
fi

echo "=== 2/4 跑 JS 参考侧 ==="
node conformance/js-runner.js "$FIXTURE" > "$OUT_DIR/js.jsonl" 2> "$OUT_DIR/js.err"
JS_LINE=$(tail -1 "$OUT_DIR/js.err")

echo "=== 3/4 比对 ==="
python3 - "$OUT_DIR/swift.jsonl" "$OUT_DIR/js.jsonl" "$OUT_DIR/report.md" <<'PY'
import json, sys
sw_path, js_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

def load(p):
    d = {}
    for line in open(p, encoding='utf-8'):
        line = line.strip()
        if not line: continue
        try: o = json.loads(line)
        except Exception: continue
        d[o['id']] = o
    return d

sw, js = load(sw_path), load(js_path)
ids = sorted(set(sw) | set(js))

rows, diffs, sw_only, js_only = [], [], 0, 0
one_side = 0
for i in ids:
    a, b = sw.get(i), js.get(i)
    a_skip = bool(a) and a.get('actual') == 'SKIPPED'
    b_skip = bool(b) and b.get('actual') == 'SKIPPED'
    if a_skip or b_skip:
        # ⭐ **只有一边能跑**（例：macOS 上 Swift 有 JSC 后端，Linux 上没有）
        #    ⇒ **不算差异**（否则 Linux 每次都多出一批假差异 ⇒ 看着像回归）
        one_side += 1
        continue
    same = a and b and a.get('actual') == b.get('actual')
    if a and not a.get('ok'): sw_only += 1
    if b and not b.get('ok'): js_only += 1
    if not same:
        diffs.append((i, a, b))

L = []
L.append('# 双实现对拍报告')
L.append('')
L.append('> Swift 侧 = **自研实现**（照 `docs/legado-semantics.md` 写的）')
L.append('> JS 侧 = **轻阅现有引擎**（`reference/js/`，只读参考，不改）')
L.append('> 同一份 fixture ⇒ **差异 = 待查的债**（可能是轻阅的 bug，也可能是规格写错了 —— 两边都要人看一眼）')
L.append('')
L.append('| 指标 | 值 |')
L.append('|---|---|')
L.append('| 用例总数 | %d |' % len(ids))
L.append('| 两边一致 | **%d** |' % (len(ids) - len(diffs)))
L.append('| 存在差异 | **%d** |' % len(diffs))
L.append('| 只有一边能跑（不算差异） | %d |' % one_side)
L.append('')
L.append('## 差异明细')
L.append('')
if not diffs:
    L.append('无 —— 两套实现语义一致 ✅')
else:
    L.append('| 用例 | 规格期望 | Swift（自研） | JS（轻阅参考） | 判定 |')
    L.append('|---|---|---|---|---|')
    for i, a, b in diffs:
        exp = (a or b or {}).get('expected', '')
        sa = (a or {}).get('actual', '（缺）')
        ja = (b or {}).get('actual', '（缺）')
        if exp and sa == exp and ja != exp:
            verdict = '**轻阅的 bug**（自研已按规格修对）'
        elif exp and ja == exp and sa != exp:
            verdict = '⚠️ **自研写错了**（轻阅对）'
        else:
            verdict = '两边都跟规格不符 ⇒ 规格要改'
        L.append('| `%s` | `%s` | `%s` | `%s` | %s |' % (i, exp, sa, ja, verdict))
L.append('')
L.append('## 说明')
L.append('')
L.append('- **Swift 侧不符**（%d 条）⇒ 自研实现还没写完 / 写错了。' % sw_only)
L.append('- **JS 侧不符**（%d 条）⇒ 轻阅现有实现与规格不一致（多数是**已知债**）。' % js_only)
L.append('- **只有一边能跑**的用例（%d 条）⇒ 例如 macOS 上 Swift 侧有 JSC 后端、Linux 上没有 ⇒ **不算差异**。' % one_side)
L.append('- 两边都跑不了的用例（`SKIPPED`）⇒ 属于后续切片（需要 DOM / JS 后端）。')
L.append('')
open(out_path, 'w', encoding='utf-8').write('\n'.join(L))
print('\n'.join(L[:14]))
print('...')
print('报告：%s' % out_path)
PY

echo "=== 4/4 汇总 ==="
echo "Swift 侧：$SWIFT_LINE"
echo "JS 侧：   $JS_LINE"
echo "报告：$OUT_DIR/report.md"
