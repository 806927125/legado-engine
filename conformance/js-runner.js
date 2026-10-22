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
 *   ⇒ 这条就是**待修的债**（多半是轻阅的 bug，或规格写错了 —— 两边都要人看一眼）。
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
      value && value.ok === false ? r.reject(new Error(value.error || 'engine error')) : r.resolve(value);
    };
  `);
  for (const f of FILES) {
    const p = path.join(ENGINE_DIR, f);
    if (!fs.existsSync(p)) continue;
    vm.runInContext(fs.readFileSync(p, 'utf8'), ctx, { filename: f });
  }
  return { dom, win, ctx };
}

const fixturePath = process.argv[2] || path.join(__dirname, 'fixtures', 'semantics-cases.json');
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
const { win } = createSandbox();
const QR = win.QR;

let pass = 0, fail = 0;
const out = [];

function emit(id, kind, expected, actual) {
  const ok = String(expected) === String(actual);
  ok ? (pass++) : (fail++);
  out.push(JSON.stringify({ id, kind, expected, actual, ok }));
}

for (const c of fixture.cases) {
  const kind = c.kind || '';
  const expect = c.expect || {};
  const ctx = c.ctx || {};
  const isJSON = !!ctx.isJSON;

  try {
    if (kind === 'classify') {
      emit(c.id, kind, expect.kind || '', QR.rule.classify(c.rule || '', { isJSON }));
    } else if (kind === 'chainSegment') {
      // 链段分类：head 视作一个子选择器，链步按 parseChain 的 kind
      const parsed = QR.dom.parseChain(c.rule || '');
      const steps = ['sub'].concat((parsed.chain || []).map(x => x.kind));
      emit(c.id, kind, expect.steps || '', steps.join(','));
    } else if (kind === 'parse') {
      // 整条规则解析 —— 参考实现没有暴露 AST ⇒ 标记为不支持
      emit(c.id, kind, expect.ast || '', 'NO_AST');
    } else {
      emit(c.id, kind, expect.kind || '', 'SKIPPED');
    }
  } catch (e) {
    emit(c.id, kind, expect.kind || '', 'ERROR:' + (e && e.message));
  }
}

out.forEach(l => console.log(l));
process.stderr.write(`JS 参考侧：通过 ${pass} / 不符合 ${fail}\n`);
