#!/usr/bin/env node
/**
 * **双实现对拍运行器**（JS 参考实现侧）
 *
 * 跑法：node conformance/js-runner.js [fixture.json]
 *
 * 加载 `reference/js/`（轻阅现有引擎，**只读，不改**）⇒ 跑同一份 fixture
 * ⇒ 输出与 Swift 侧**同构**的 JSON 行：
 *   `{"id":…,"kind":…,"expected":…,"actual":…,"ok":…}`
 *
 * ⭐ 差异 = 债：
 *   Swift 侧（照规格写的）通过，JS 参考侧（轻阅现有实现）不通过
 *   ⇒ 这条就是**待修的债**（多半是轻阅的 bug，也可能是规格写错了 —— 两边都要人看一眼）。
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM } = require('jsdom');

const ROOT = path.join(__dirname, '..');
const ENGINE_DIR = path.join(ROOT, 'reference', 'js');
// 顺序必须与轻阅 `test/harness.js` 一致
const FILES = [
  'jsoup-compat.js',
  'sextant-filter.js',
  'jsonpath.js',
  'org-jsoup.js',
  'sha1.js',
  'java-api.js',
  'packages-native.js',
  'packages_stub.js',
  'source-api.js',
  'rule-analyzer.js',
  'engine.js',
];

function createSandbox() {
  const dom = new JSDOM('<!doctype html><html><head></head><body></body></html>',
    { url: 'https://book.example.com/', runScripts: 'outside-only', pretendToBeVisual: true });
  const win = dom.window;
  const ctx = dom.getInternalVMContext();
  win.__nativeCalls = [];
  win.__nativeMock = async () => ({ ok: true, value: '' });
  win.webkit = { messageHandlers: { qr: { postMessage() {} } } };
  win.eval(`
    window.__qrSeq = 0; window.__qrPending = {};
    window.__qrResolve = function (id, value) {
      var r = window.__qrPending[id]; if (!r) return; delete window.__qrPending[id];
      value && value.ok === false
        ? r.reject(new Error(value.error || 'engine error'))
        : r.resolve(value && 'value' in value ? value.value : value);
    };
  `);
  for (const f of FILES) {
    const p = path.join(ENGINE_DIR, f);
    if (!fs.existsSync(p)) continue;
    vm.runInContext(fs.readFileSync(p, 'utf8'), ctx, { filename: f });
  }
  return { dom, win, ctx };
}

// ⚠️ 模块级 —— helper 函数要用
const { win } = createSandbox();
const QR = win.QR;

const fixturePath = process.argv[2] || path.join(__dirname, 'fixtures', 'semantics-cases.json');
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));

let pass = 0, fail = 0;
const out = [];

function emit(id, kind, expected, actual) {
  const ok = String(expected) === String(actual);
  ok ? (pass++) : (fail++);
  out.push(JSON.stringify({ id, kind, expected, actual, ok }));
}

// ================================================================
// 基准 / 上下文
// ================================================================

function buildBase(spec, ctxSpec) {
  if (!spec) return '';
  if (spec.type === 'json') return spec.value;
  if (spec.type === 'text') return spec.value || '';
  if (spec.type === 'null') return null;
  if (spec.type === 'html') {
    // ⚠️ 必须用 **vm 作用域里的 QR**
    return QR.dom.parseHTML(spec.value || '', ctxSpec.baseUrl || 'https://book.example.com/');
  }
  return null;
}

function buildCtx(spec, base) {
  const raw = spec.raw !== undefined ? spec.raw
    : (spec.type === 'html' ? (spec.value || '') : '');
  return {
    baseUrl: spec.baseUrl || 'https://book.example.com/',
    raw: raw,
    isJSON: !!spec.isJSON,
    page: spec.page || 1,
    key: spec.key || '',
    vars: spec.vars || {},
    source: spec.source || null,
    book: spec.book || null,
  };
}

// ================================================================
// 期望值 / 实际值（同构 ⇒ 逐字可比）
// ================================================================

const KEYS = ['count', 'texts', 'value', 'values', 'contains'];

function comparePayload(expect, texts) {
  const parts = [];
  for (const k of KEYS) {
    if (!(k in expect)) continue;
    if (k === 'contains') {
      // 期望侧固定为 "1"（期望成立）⇒ 实际不含该子串时 actual 是 "" ⇒ 不等 ⇒ 失败
      parts.push('"contains":"1"');
    } else {
      parts.push('"' + k + '":' + jsonAny(expect[k]));
    }
  }
  return '{' + parts.join(',') + '}';
}

function actualPayload(expect, texts) {
  const parts = [];
  for (const k of KEYS) {
    if (!(k in expect)) continue;
    if (k === 'count') parts.push('"count":' + texts.length);
    else if (k === 'texts') parts.push('"texts":' + JSON.stringify(texts));
    else if (k === 'value') parts.push('"value":' + JSON.stringify(texts[0] === undefined ? '' : texts[0]));
    else if (k === 'values') parts.push('"values":' + JSON.stringify(texts));
    else if (k === 'contains') {
      parts.push('"contains":' + JSON.stringify(texts.some(t => String(t).includes(expect[k])) ? '1' : ''));
    }
  }
  return '{' + parts.join(',') + '}';
}

function jsonAny(v) {
  if (typeof v === 'string') return JSON.stringify(v);
  if (v && typeof v === 'object') return JSON.stringify(v);
  return JSON.stringify(v);
}

// ================================================================
// 主流程
// ================================================================

(async () => {
  for (const c of fixture.cases) {
    const kind = c.kind || '';
    const expect = c.expect || {};
    const ctxSpec = c.ctx || {};

    // ⭐ **requires 门槛**：需要 JS 后端的用例 ⇒ 两边都跳过（Swift 侧 Phase 3 才接 JSC）
    if (c.requires === 'js') {
      emit(c.id, kind, 'SKIPPED', 'SKIPPED');
      continue;
    }

    try {
      if (kind === 'classify') {
        emit(c.id, kind, expect.kind || '',
             QR.rule.classify(c.rule || '', { isJSON: !!ctxSpec.isJSON }));

      } else if (kind === 'chainSegment') {
        const parsed = QR.dom.parseChain(c.rule || '');
        const steps = (parsed.chain || []).map(x => x.kind);
        emit(c.id, kind, expect.steps || '', steps.join(','));

      } else if (kind === 'headCss') {
        const parsed = QR.dom.parseChain(c.rule || '');
        emit(c.id, kind, expect.css || '', parsed.selector || '');

      } else if (kind === 'domSelect') {
        const doc = QR.dom.parseHTML(c.html || '', ctxSpec.baseUrl || 'https://book.example.com/');
        let nodes = [];
        try { nodes = QR.dom.selectAll(doc, c.rule || '') || []; } catch (e) { nodes = []; }
        const texts = nodes.map(n => QR.dom.textOf(n));
        emit(c.id, kind,
          comparePayload(expect, texts),
          actualPayload(expect, texts));

      } else if (kind === 'evalOne' || kind === 'getElements') {
        const base = buildBase(c.base, ctxSpec);
        const ctx = buildCtx(ctxSpec, c.base || {});
        let outVals = [];
        try {
          if (kind === 'evalOne') {
            outVals = await QR.rule.evalOne(c.rule || '', base, ctx);
          } else {
            const r = await QR.rule.getElements(c.rule || '', base, ctx);
            // 轻阅的 getElements 返回 {values:[…], rule:'…'} 或数组
            if (Array.isArray(r)) outVals = r;
            else if (r && Array.isArray(r.values)) outVals = r.values;
            else outVals = [];
          }
        } catch (e) { outVals = []; }
        if (!Array.isArray(outVals)) outVals = outVals === undefined || outVals === null ? [] : [outVals];
        const texts = outVals.map(x => (typeof x === 'string' ? x : JSON.stringify(x)));
        emit(c.id, kind, comparePayload(expect, texts), actualPayload(expect, texts));

      } else if (kind === 'jsScope') {
        // 作用域观察：JS 侧暂不支持 ⇒ 跳过（Phase 3 接 JSC 后再对拍）
        emit(c.id, kind, 'SKIPPED', 'SKIPPED');

      } else {
        emit(c.id, kind, 'SKIPPED', 'SKIPPED');
      }
    } catch (e) {
      emit(c.id, kind, expect.kind || '', 'ERROR:' + (e && e.message));
    }
  }

  out.forEach(l => console.log(l));
  process.stderr.write(`JS 参考侧：通过 ${pass} / 不符合 ${fail}\n`);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
