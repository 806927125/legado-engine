#!/usr/bin/env node
/**
 * **Legado 语义符合度体检**
 *
 * 跑法：node test/semantics-conformance.test.js [--gate]
 *
 * ────────────────────────────────────────────────────────────
 * 这不是「门禁」，是**符合度体检**：
 *   读 test/fixtures/semantics-cases.json（每条用例引用 docs/legado-semantics.md 里的语义 id）
 *   → 用**当前引擎**跑一遍
 *   → 产出 docs/现状符合度报告.md
 *
 * 不符合 = **债**（不是回归）。所以默认 exit 0；
 * 债还清之后加 --gate 就能当门禁用（任一不符即红）。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const ROOT = path.join(__dirname, '..');
const FIXTURE = path.join(__dirname, 'fixtures', 'semantics-cases.json');
const REPORT = path.join(ROOT, 'docs', '现状符合度报告.md');
const GATE = process.argv.includes('--gate');

let pass = 0, fail = 0;
const failures = [];
const ok = (c, m) => { if (c) { pass++; return true; } fail++; console.log('  x ' + m); return false; };

/* ── 基座构造（在沙盒内做，因为要用 QR.dom） ───────────────── */
function buildBase(win, spec, baseUrl) {
  return win.eval(`(function(){
    var s = ${JSON.stringify(spec || null)};
    if (!s) return null;
    if (s.type === 'json')  return s.value;
    if (s.type === 'text')  return s.value;
    if (s.type === 'null')  return null;
    if (s.type === 'number')return s.value;
    if (s.type === 'html')  return QR.dom.parseHTML(s.value, ${JSON.stringify(baseUrl || '')});
    if (s.type === 'element') {
      var doc = QR.dom.parseHTML(s.value, ${JSON.stringify(baseUrl || '')});
      try { return QR.dom.selectOne(doc, s.selector); } catch (e) { return null; }
    }
    return null;
  })()`);
}

function buildCtx(win, spec) {
  const c = spec || {};
  return {
    baseUrl: c.baseUrl || '',
    isJSON: !!c.isJSON,
    raw: c.raw !== undefined ? c.raw : undefined,
    page: c.page || 1,
    book: c.book || undefined,
    source: c.source || undefined,
    chapter: c.chapter || undefined
  };
}

/* ── 期望比对 ─────────────────────────────────────────────── */
/**
 * jsScope 用例有两种观察对象：
 *   target:"scope"  → 看**作用域本身**（有没有 raw / key / baseUrl）
 *   target:"result"（默认）→ 看作用域里的 **result**（S-RES 分层的结果）
 */
function pickScopeTarget(scope, c) {
  const t = (c.expect && c.expect.target) || 'result';
  if (t === 'scope') return scope;
  if (t === 'result') return scope && Object.prototype.hasOwnProperty.call(scope, 'result')
    ? scope.result : scope;
  return scope;
}

function same(a, b) {
  if (a === b) return true;
  try { return JSON.stringify(a) === JSON.stringify(b); } catch (e) { return false; }
}
function check(expect, actual) {
  if (expect.kind !== undefined) return { ok: actual === expect.kind, actual: actual };
  if (expect.count !== undefined) {
    const n = Array.isArray(actual) ? actual.length : -1;
    return { ok: n === expect.count, actual: '共 ' + n + ' 项' };
  }
  if (expect.values !== undefined) {
    const a = Array.isArray(actual) ? actual : [actual];
    return { ok: same(a, expect.values), actual: JSON.stringify(a) };
  }
  if (expect.value !== undefined) {
    const a = Array.isArray(actual) ? actual[0] : actual;
    return { ok: same(a, expect.value), actual: JSON.stringify(a) };
  }
  if (expect.contains !== undefined) {
    const a = Array.isArray(actual) ? actual : [actual];
    const hit = a.some(x => String(x).indexOf(expect.contains) >= 0);
    return { ok: hit, actual: JSON.stringify(a).slice(0, 160) };
  }
  if (expect.has !== undefined) {
    const has = actual && typeof actual === 'object' && (expect.has in actual);
    return { ok: has, actual: has ? '有 ' + expect.has : '缺 ' + expect.has + '（现有键：' + Object.keys(actual || {}).join(',') + '）' };
  }
  return { ok: false, actual: '(未知期望格式)' };
}

(async () => {
  const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  const { win } = createSandbox();
  const QR = win.QR;

  console.log('=== Legado 语义符合度体检 ===');
  console.log('用例 ' + fixture.cases.length + ' 条\n');

  for (const c of fixture.cases) {
    const ctx = buildCtx(win, c.ctx);
    // @put/@get 的变量仓在 QR.runtime.vars
    if (c.ctx && c.ctx.vars) {
      QR.runtime.vars = QR.runtime.vars || {};
      for (const k of Object.keys(c.ctx.vars)) QR.runtime.vars[k] = c.ctx.vars[k];
    }

    let actual = null, err = null;
    try {
      if (c.kind === 'classify') {
        actual = QR.rule.classify(c.rule, ctx);
      } else if (c.kind === 'evalOne') {
        const base = buildBase(win, c.base, ctx.baseUrl);
        actual = await QR.rule.evalOne(c.rule, base, ctx);
      } else if (c.kind === 'getElements') {
        // 列表/兜底链专用入口：|| 和 && 的拆分在这里面
        const base = buildBase(win, c.base, ctx.baseUrl);
        const r = await QR.rule.getElements(c.rule, base, ctx);
        // getElements 返回 {values:[...], rule:'...'}（也有返回数组的旧形态）—— 摊平成字符串数组
        if (r && !Array.isArray(r) && Array.isArray(r.values)) actual = r.values;
        else if (Array.isArray(r)) actual = r.map(x => (x && Array.isArray(x.values)) ? x.values : x)
                                          .reduce((a, b) => a.concat(b), []);
        else actual = r;
      } else if (c.kind === 'jsScope') {
        const base = buildBase(win, c.base, ctx.baseUrl);
        actual = QR.rule.makeScope(QR.rule.jsScope(base, base, ctx, c.rule || ''));
      } else {
        err = '未知用例类型 ' + c.kind;
      }
    } catch (e) {
      err = String((e && e.message) || e);
    }

    let res;
    if (err) res = { ok: false, actual: '抛异常：' + err };
    else res = check(c.expect, c.kind === 'jsScope' ? pickScopeTarget(actual, c) : actual);

    if (res.ok) {
      pass++;
      console.log('  ✓ [' + c.id + '] ' + c.title);
    } else {
      fail++;
      console.log('  x [' + c.id + '] ' + c.title + '  ⇒  ' + res.actual);
      failures.push({ c, actual: res.actual });
    }
  }

  /* ── 报告 ───────────────────────────────────────────────── */
  const byDomain = {};
  for (const c of fixture.cases) {
    const dom = String(c.semantic).replace(/-\d+$/, '');
    byDomain[dom] = byDomain[dom] || { total: 0, bad: 0 };
    byDomain[dom].total++;
  }
  for (const f of failures) {
    const dom = String(f.c.semantic).replace(/-\d+$/, '');
    byDomain[dom].bad++;
  }

  const lines = [];
  lines.push('# 现状符合度报告');
  lines.push('');
  lines.push('> 生成方式：`node test/semantics-conformance.test.js`（**只读**，不改引擎）');
  lines.push('> 规格：`docs/legado-semantics.md` · 用例：`test/fixtures/semantics-cases.json`');
  lines.push('> 引擎：`QiReaderLite/Resources/engine/` @ ' + (process.env.ENGINE_REV || 'HEAD'));
  lines.push('');
  lines.push('## 总览');
  lines.push('');
  lines.push('| 指标 | 值 |');
  lines.push('|---|---|');
  lines.push('| 用例总数 | ' + fixture.cases.length + ' |');
  lines.push('| 符合 | **' + pass + '** |');
  lines.push('| 不符合（债） | **' + fail + '** |');
  lines.push('| 符合率 | ' + (fixture.cases.length ? Math.round(pass * 100 / fixture.cases.length) : 0) + '% |');
  lines.push('');
  lines.push('## 按语义域');
  lines.push('');
  lines.push('| 语义域 | 用例 | 不符合 |');
  lines.push('|---|---|---|');
  for (const k of Object.keys(byDomain).sort()) {
    lines.push('| `' + k + '` | ' + byDomain[k].total + ' | ' + (byDomain[k].bad ? '**' + byDomain[k].bad + '**' : '0') + ' |');
  }
  lines.push('');

  if (failures.length) {
    lines.push('## 不符合明细（= 债）');
    lines.push('');
    lines.push('| 用例 | 语义 | 标题 | 期望 | 实际 |');
    lines.push('|---|---|---|---|---|');
    for (const f of failures) {
      lines.push('| `' + f.c.id + '` | `' + f.c.semantic + '` | ' + f.c.title +
        ' | `' + JSON.stringify(f.c.expect) + '` | ' + String(f.actual).replace(/\|/g, '\\|').slice(0, 120) + ' |');
    }
    lines.push('');
  } else {
    lines.push('## 不符合明细');
    lines.push('');
    lines.push('无。**全部用例符合规范。**');
    lines.push('');
  }

  lines.push('## 说明');
  lines.push('');
  lines.push('- 本报告是**体检**，不是门禁。默认 `exit 0`；加 `--gate` 才在有不符合时 exit 1。');
  lines.push('- 「不符合」= 引擎当前行为与 `docs/legado-semantics.md` 不一致 —— 每一项都是**可执行的债**。');
  lines.push('- 修法优先级：**静默失败/静默损坏 > 行为不一致 > 缺功能**（沿用 `栖阅-轻阅-引擎对账.md` §5 的判据）。');
  lines.push('- 新增语义时：先在 `docs/legado-semantics.md` 写条目 → 再在 `semantics-cases.json` 加用例 → 跑本脚本。');
  lines.push('');
  lines.push('## ⭐ 重点债（本次体检挖出来的，按修法优先级）');
  lines.push('');
  lines.push('### 债 1 ⛔【重量级】链段里的**裸标签名**被当成了属性名 → 链断');
  lines.push('');
  lines.push('- **语义**：`S-SEL-06` · **影响面**：125 源里 **279 处、60 个源（48%）**');
  lines.push('- **机理**：`jsoup-compat.js:218` 的 `if (dot >= 0 && (KW[kw] || isHtmlTag(kw)))` —— 裸名没有 `kw.` 前缀 ⇒ 走 else ⇒ 当成**属性**');
  lines.push('- **症状**：`class.catalog_ls@li` 取到的是 `<ul>` 自己 ⇒ **目录只有 1 章**（章名全拼一起）；');
  lines.push('  `.searchList@li` ⇒ **搜索只出 1 本**；`.lis@li` ⇒ **发现页出不来**；`.sidebar@img@src` ⇒ **封面空白**');
  lines.push('- **修法**：`parseChain` 的 else 分支分流 —— 裸名在**属性白名单**（text/html/href/src/…）里 ⇒ attr 步；');
  lines.push('  否则 ⇒ sub 步（按标签名找子元素）');
  lines.push('- ⚠️ **风险**：一改就影响 60 个源的解析结果（1 条变 N 条）⇒ **必须配活体回归**，不能只看离线用例绿不绿');
  lines.push('');
  lines.push('### 债 2 ⛔ `flatten()` 吃掉了 `{title, url}` 对象的**标题**');
  lines.push('');
  lines.push('- **语义**：`S-JSON-06` · **机理**：`dom.textOf(el)` 读 `el.textContent`，传**字符串**进去 ⇒ 返回 `\'\'`');
  lines.push('- **症状**：单值规则（`evalJsonPath` → `flatten`）拿到 `{title,url}` ⇒ 结果是 `"\\tu1"`，**标题整段没了**');
  lines.push('- **隐蔽性**：列表路径（`evalJsonPathList`）不 flatten ⇒ **列表看着正常** ⇒ 只有单值规则受害');
  lines.push('');

  fs.mkdirSync(path.dirname(REPORT), { recursive: true });
  fs.writeFileSync(REPORT, lines.join('\n'), 'utf8');

  console.log('\n' + (fail === 0 ? '✅' : '⚠️') + ' 符合 ' + pass + ' / 不符合 ' + fail);
  console.log('报告：' + path.relative(ROOT, REPORT));
  process.exit(GATE && fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
